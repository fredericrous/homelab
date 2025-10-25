#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

NAS_KUBECONFIG="${ROOT_DIR}/infrastructure/nas/kubeconfig.yaml"
HOMELAB_KUBECONFIG="${KUBECONFIG:-${ROOT_DIR}/kubeconfig}"

log_info "Ensuring Istio CA is set up across clusters..."

# Check prerequisites
check_command kubectl
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

# Step 1: Create NAS kubeconfig secret in homelab
log_info "Creating NAS kubeconfig secret in homelab cluster..."
kubectl --kubeconfig="$HOMELAB_KUBECONFIG" create namespace istio-system --dry-run=client -o yaml | \
    kubectl --kubeconfig="$HOMELAB_KUBECONFIG" apply -f - >/dev/null

# Create the secret with actual kubeconfig
kubectl --kubeconfig="$HOMELAB_KUBECONFIG" -n istio-system create secret generic nas-kubeconfig \
    --from-file=config="$NAS_KUBECONFIG" \
    --dry-run=client -o yaml | \
    kubectl --kubeconfig="$HOMELAB_KUBECONFIG" apply -f - >/dev/null

log_success "NAS kubeconfig secret created"

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