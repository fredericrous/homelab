#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

NAS_KUBECONFIG="${ROOT_DIR}/infrastructure/nas/kubeconfig.yaml"
HOMELAB_KUBECONFIG="${KUBECONFIG:-${ROOT_DIR}/kubeconfig}"

log_info "Ensuring Istio CA is set up across clusters..."

# Helper to read a key from .env without exporting everything
get_env_value() {
    local key="$1"
    local env_file="${ROOT_DIR}/.env"
    if [[ -f "$env_file" ]]; then
        local line
        line=$(grep -E "^[[:space:]]*${key}=" "$env_file" | tail -n 1 || true)
        if [[ -n "$line" ]]; then
            line="${line#*=}"
            line="$(echo "$line" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
            echo "$line"
        fi
    fi
}

# Check prerequisites
check_command kubectl
check_command vault
check_file "$HOMELAB_KUBECONFIG" "Homelab kubeconfig"
check_file "$NAS_KUBECONFIG" "NAS kubeconfig"

# Function to wait for a secret
wait_for_secret() {
    local kubeconfig="$1"
    local namespace="$2"
    local secret="$3"
    local timeout="${4:-300}"
    
    log_info "Waiting for secret $secret in namespace $namespace..."
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if kubectl --kubeconfig="$kubeconfig" -n "$namespace" get secret "$secret" >/dev/null 2>&1; then
            log_success "Secret $secret found"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    log_error "Timeout waiting for secret $secret"
    return 1
}

# Function to get CA fingerprint
get_ca_fingerprint() {
    local kubeconfig="$1"
    kubectl --kubeconfig="$kubeconfig" -n istio-system get secret cacerts \
        -o jsonpath='{.data.root-cert\.pem}' 2>/dev/null | \
        base64 -d | openssl x509 -fingerprint -noout 2>/dev/null | cut -d= -f2 || echo ""
}

# Step 1: Push NAS kubeconfig into Vault for ExternalSecret
VAULT_ADDR="${VAULT_ADDR:-$(get_env_value VAULT_ADDR)}"
VAULT_ADDR="${VAULT_ADDR:-http://vault-vault.vault.svc.cluster.local:8200}"
export VAULT_ADDR

VAULT_TOKEN="${VAULT_TOKEN:-$(get_env_value VAULT_TOKEN)}"
export VAULT_TOKEN

if [ -z "${VAULT_TOKEN:-}" ]; then
    # Last resort: try to read admin token from the cluster if Vault is already initialized
    ADMIN_TOKEN=$(kubectl --kubeconfig="$HOMELAB_KUBECONFIG" -n vault get secret vault-admin-token \
        -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
    if [[ -n "$ADMIN_TOKEN" ]]; then
        VAULT_TOKEN="$ADMIN_TOKEN"
        export VAULT_TOKEN
        log_success "Discovered Vault admin token from cluster secret"
    fi
fi

if [ -z "${VAULT_TOKEN:-}" ]; then
    log_error "VAULT_TOKEN is required to push NAS kubeconfig into Vault (secret/kubeconfigs/nas). Set it in .env or export it before running."
    exit 1
fi

log_info "Publishing NAS kubeconfig to Vault path secret/kubeconfigs/nas..."
vault kv put secret/kubeconfigs/nas kubeconfig=@"${NAS_KUBECONFIG}"
log_success "NAS kubeconfig stored in Vault"

# Ensure ExternalSecret target namespace exists so nas-kubeconfig secret can materialize
kubectl --kubeconfig="$HOMELAB_KUBECONFIG" create namespace istio-system --dry-run=client -o yaml | \
    kubectl --kubeconfig="$HOMELAB_KUBECONFIG" apply -f - >/dev/null

# Step 2: Trigger Flux reconciliation for CA bootstrap
log_info "Reconciling CA bootstrap kustomization..."
if flux --kubeconfig="$HOMELAB_KUBECONFIG" get kustomization istio-ca-bootstrap >/dev/null 2>&1; then
    flux --kubeconfig="$HOMELAB_KUBECONFIG" reconcile kustomization istio-ca-bootstrap --with-source
else
    log_warn "istio-ca-bootstrap kustomization not found, it will be created by platform-foundation"
fi

# Step 3: Wait for CA to be generated in homelab
if ! wait_for_secret "$HOMELAB_KUBECONFIG" "istio-system" "cacerts"; then
    log_error "Failed to generate CA in homelab cluster"
    exit 1
fi

HOMELAB_FP=$(get_ca_fingerprint "$HOMELAB_KUBECONFIG")
log_info "Homelab CA fingerprint: $HOMELAB_FP"

# Step 4: Wait for sync job to complete
log_info "Waiting for CA sync job to complete..."
kubectl --kubeconfig="$HOMELAB_KUBECONFIG" -n istio-system wait \
    --for=condition=complete job/istio-ca-sync-to-nas \
    --timeout=5m || {
    log_warn "Sync job not completed yet, checking NAS directly..."
}

# Step 5: Verify CA is synced to NAS
log_info "Verifying CA in NAS cluster..."
kubectl --kubeconfig="$NAS_KUBECONFIG" create namespace istio-system --dry-run=client -o yaml | \
    kubectl --kubeconfig="$NAS_KUBECONFIG" apply -f - >/dev/null

if wait_for_secret "$NAS_KUBECONFIG" "istio-system" "cacerts" 60; then
    NAS_FP=$(get_ca_fingerprint "$NAS_KUBECONFIG")
    log_info "NAS CA fingerprint: $NAS_FP"
    
    if [ "$HOMELAB_FP" = "$NAS_FP" ]; then
        log_success "CA successfully synced to both clusters with matching fingerprints"
    else
        log_error "CA fingerprints don't match between clusters!"
        log_error "Homelab: $HOMELAB_FP"
        log_error "NAS:     $NAS_FP"
        exit 1
    fi
else
    log_error "CA not found in NAS cluster"
    exit 1
fi

# Step 6: Trigger Istio reconciliation in both clusters
log_info "Triggering Istio component reconciliation..."

# Homelab
for component in istio-base istiod istio-eastwestgateway; do
    if flux --kubeconfig="$HOMELAB_KUBECONFIG" get helmrelease "$component" -n flux-system >/dev/null 2>&1; then
        flux --kubeconfig="$HOMELAB_KUBECONFIG" reconcile helmrelease "$component" -n flux-system || true
    fi
done

# NAS
for component in istio-base istio-eastwestgateway; do
    if flux --kubeconfig="$NAS_KUBECONFIG" get helmrelease "$component" -n flux-system >/dev/null 2>&1; then
        flux --kubeconfig="$NAS_KUBECONFIG" reconcile helmrelease "$component" -n flux-system || true
    fi
done

log_success "Istio CA setup completed successfully!"
log_info "Both clusters now share the same root CA for mTLS communication"
