#!/bin/bash
# sync-vault-v2.sh - Simplified Vault deployment sync script
# Focuses on core functionality with better error handling

set -euo pipefail

# Parameters
KUBECONFIG="${1:?Error: KUBECONFIG path required as first argument}"
export KUBECONFIG

# Configuration
VAULT_NAMESPACE="vault"
ARGOCD_NAMESPACE="argocd"
TRANSIT_TOKEN_FILE="${VAULT_TRANSIT_TOKEN_FILE:-/tmp/vault-transit-token}"
TRANSIT_ENV_FILE="/tmp/vault-transit-env"
MAX_WAIT=600

# Import common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Logging functions
log_info() { echo "ℹ️  $*"; }
log_success() { echo "✅ $*"; }
log_error() { echo "❌ $*" >&2; }
log_warn() { echo "⚠️  $*" >&2; }

# Cleanup on exit
cleanup() {
    unset K8S_VAULT_TRANSIT_TOKEN VAULT_TOKEN
}
trap cleanup EXIT

# Read transit token with fallback options
read_transit_token() {
    local token=""
    
    # Priority 1: Secure file
    if [ -f "$TRANSIT_TOKEN_FILE" ] && [ -r "$TRANSIT_TOKEN_FILE" ]; then
        log_info "Reading transit token from secure file"
        token=$(cat "$TRANSIT_TOKEN_FILE")
        chmod 600 "$TRANSIT_TOKEN_FILE" 2>/dev/null || true
    # Priority 2: Environment file from Taskfile
    elif [ -f "$TRANSIT_ENV_FILE" ]; then
        log_info "Reading transit token from Taskfile environment"
        token=$(grep "K8S_VAULT_TRANSIT_TOKEN=" "$TRANSIT_ENV_FILE" | cut -d'=' -f2- | tr -d '"')
    # Priority 3: QNAP Vault lookup
    elif [ -n "${QNAP_VAULT_TOKEN:-}" ] && command -v vault >/dev/null 2>&1; then
        log_info "Fetching transit token from QNAP Vault"
        export VAULT_ADDR=http://192.168.1.42:61200
        export VAULT_TOKEN="$QNAP_VAULT_TOKEN"
        token=$(vault kv get -field=token secret/k8s-transit 2>/dev/null || echo "")
        unset VAULT_ADDR VAULT_TOKEN
    fi
    
    if [ -z "$token" ]; then
        log_error "Transit token not found"
        return 1
    fi
    
    echo "$token"
}

# Ensure transit token secret exists
setup_transit_token() {
    local token="${1}"
    
    log_info "Setting up transit token secret"
    
    # Create namespace
    kubectl create namespace "$VAULT_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    
    # Check existing secret
    local existing_token
    existing_token=$(kubectl get secret vault-transit-token -n "$VAULT_NAMESPACE" \
        -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    
    if [ "$existing_token" = "PLACEHOLDER_WILL_BE_REPLACED_BY_TERRAFORM" ] || \
       [ -z "$existing_token" ] || \
       [ "$existing_token" != "$token" ]; then
        log_info "Updating transit token secret"
        kubectl create secret generic vault-transit-token \
            --namespace="$VAULT_NAMESPACE" \
            --from-literal=token="$token" \
            --dry-run=client -o yaml | kubectl apply -f -
    else
        log_success "Transit token secret already up to date"
    fi
    
    # Save to secure file for future runs
    if [ ! -f "$TRANSIT_TOKEN_FILE" ]; then
        echo "$token" > "$TRANSIT_TOKEN_FILE"
        chmod 600 "$TRANSIT_TOKEN_FILE"
    fi
}

# Wait for ArgoCD application
wait_for_app() {
    local app_name="${1}"
    local timeout="${2:-150}"
    
    log_info "Waiting for $app_name application"
    
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if kubectl get app -n "$ARGOCD_NAMESPACE" "$app_name" &>/dev/null; then
            log_success "$app_name application found"
            return 0
        fi
        sleep 5
        ((elapsed+=5))
    done
    
    log_error "Timeout waiting for $app_name application"
    return 1
}

# Sync application
sync_app() {
    local app_name="${1}"
    
    log_info "Syncing $app_name application"
    
    # Force refresh to clear cache
    kubectl patch app -n "$ARGOCD_NAMESPACE" "$app_name" --type merge \
        -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' || true
    
    sleep 3
    
    # Trigger sync
    kubectl patch app -n "$ARGOCD_NAMESPACE" "$app_name" --type merge -p '{
        "operation": {
            "initiatedBy": {"username": "terraform"},
            "sync": {
                "prune": true,
                "syncStrategy": {"hook": {}},
                "revision": "HEAD"
            }
        }
    }'
}

# Check Vault deployment
check_vault_deployment() {
    local timeout="${1:-300}"
    local elapsed=0
    
    log_info "Checking Vault deployment status"
    
    while [ $elapsed -lt $timeout ]; do
        # Check if Vault pod exists and is running
        if kubectl get pod -n "$VAULT_NAMESPACE" vault-0 &>/dev/null; then
            local pod_phase=$(kubectl get pod -n "$VAULT_NAMESPACE" vault-0 -o jsonpath='{.status.phase}')
            
            if [ "$pod_phase" = "Running" ]; then
                log_success "Vault pod is running"
                
                # Run initialization helper
                if "$SCRIPT_DIR/vault-init-helper.sh"; then
                    log_success "Vault initialized successfully"
                    return 0
                else
                    log_warn "Vault initialization needs manual intervention"
                    return 1
                fi
            fi
        fi
        
        sleep 10
        ((elapsed+=10))
    done
    
    log_error "Timeout waiting for Vault deployment"
    return 1
}

# Main execution
main() {
    log_info "Starting Vault synchronization"
    
    # Get transit token
    K8S_VAULT_TRANSIT_TOKEN=$(read_transit_token) || {
        log_error "Failed to obtain transit token"
        cat >&2 <<EOF

To deploy, you need to:
1. Ensure QNAP Vault is accessible
2. Either:
   - Export QNAP_VAULT_TOKEN environment variable
   - Or ensure transit token exists in $TRANSIT_TOKEN_FILE
   - Or run 'task nas:vault-transit' to set up tokens
EOF
        exit 1
    }
    
    # Setup transit token secret
    setup_transit_token "$K8S_VAULT_TRANSIT_TOKEN"
    
    # Clear token from memory
    unset K8S_VAULT_TRANSIT_TOKEN
    
    # Wait for Vault app
    if ! wait_for_app "vault"; then
        exit 1
    fi
    
    # Sync Vault
    sync_app "vault"
    
    # Check deployment
    if ! check_vault_deployment; then
        log_error "Vault deployment failed"
        exit 1
    fi
    
    log_success "Vault synchronization complete"
}

# Run main function
main "$@"