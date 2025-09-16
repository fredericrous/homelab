#!/bin/bash
# vault-sync-enhanced.sh - Enhanced Vault deployment sync with full automation
# Combines simplicity of v2 with critical automation features from v1

set -euo pipefail

# Parameters
KUBECONFIG="${1:?Error: KUBECONFIG path required as first argument}"
ARG_TOKEN="${2:-}"  # Optional second argument for transit token

# Use argument if provided, otherwise use environment
K8S_VAULT_TRANSIT_TOKEN="${ARG_TOKEN:-${K8S_VAULT_TRANSIT_TOKEN:-}}"
export KUBECONFIG

# Configuration
VAULT_NAMESPACE="vault"
ARGOCD_NAMESPACE="argocd"
# Check for deployment environment file
TRANSIT_ENV_FILE="$(dirname "$0")/../../.task/.homelab-deploy-env"
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
    unset VAULT_TOKEN
}
trap cleanup EXIT

# Read transit token with fallback options
read_transit_token() {
    local token=""
    
    # Priority 1: Passed as argument (already in K8S_VAULT_TRANSIT_TOKEN)
    if [ -n "${K8S_VAULT_TRANSIT_TOKEN:-}" ]; then
        log_info "Using transit token from argument/environment"
        token="$K8S_VAULT_TRANSIT_TOKEN"
    # Priority 2: Deployment environment file
    elif [ -f "$TRANSIT_ENV_FILE" ]; then
        log_info "Reading transit token from deployment environment file: $TRANSIT_ENV_FILE"
        token=$(grep "K8S_VAULT_TRANSIT_TOKEN=" "$TRANSIT_ENV_FILE" | cut -d'=' -f2- | tr -d '"' | sed 's/^export //')
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
    
    # Quick validation - check if token looks valid (not a placeholder)
    if [ "$token" = "PLACEHOLDER_WILL_BE_REPLACED_BY_TERRAFORM" ]; then
        log_error "Transit token is still a placeholder!"
        log_error "You need to provide a valid transit token"
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
}

# Clear ArgoCD cache if needed
clear_argocd_cache() {
    local app_name="${1}"
    
    log_warn "Clearing ArgoCD cache for $app_name"
    
    # Force hard refresh
    kubectl patch app -n "$ARGOCD_NAMESPACE" "$app_name" --type merge \
        -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' || true
    
    # If persistent issues, restart repo-server
    if kubectl get app -n "$ARGOCD_NAMESPACE" "$app_name" -o json | \
       jq -r '.status.conditions[0].message // ""' | \
       grep -q "Manifest generation error (cached)"; then
        log_warn "Restarting ArgoCD repo-server to clear persistent cache"
        kubectl rollout restart deployment/argocd-repo-server -n "$ARGOCD_NAMESPACE"
        kubectl rollout status deployment/argocd-repo-server -n "$ARGOCD_NAMESPACE" --timeout=120s || true
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

# Sync application with retry
sync_app() {
    local app_name="${1}"
    local retries=3
    
    for i in $(seq 1 $retries); do
        log_info "Syncing $app_name application (attempt $i/$retries)"
        
        # Clear cache if not first attempt
        if [ $i -gt 1 ]; then
            clear_argocd_cache "$app_name"
            sleep 10
        fi
        
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
        
        # Wait for sync to start
        sleep 5
        
        # Check if sync started successfully
        local op_phase=$(kubectl get app -n "$ARGOCD_NAMESPACE" "$app_name" \
            -o jsonpath='{.status.operationState.phase}' 2>/dev/null || echo "")
        
        if [ "$op_phase" != "Error" ] && [ "$op_phase" != "Failed" ]; then
            return 0
        fi
        
        log_warn "Sync failed with phase: $op_phase"
    done
    
    return 1
}

# Wait for Vault PVC
wait_for_vault_pvc() {
    local timeout="${1:-300}"
    local elapsed=0
    
    log_info "Waiting for Vault PVC to be bound"
    
    while [ $elapsed -lt $timeout ]; do
        local pvc_status=$(kubectl get pvc -n "$VAULT_NAMESPACE" vault-data \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        
        if [ "$pvc_status" = "Bound" ]; then
            log_success "Vault PVC is bound"
            return 0
        elif [ "$pvc_status" = "Pending" ]; then
            log_info "PVC is pending, checking events..."
            kubectl get events -n "$VAULT_NAMESPACE" \
                --field-selector involvedObject.name=vault-data \
                --sort-by='.lastTimestamp' | tail -3
        fi
        
        sleep 5
        ((elapsed+=5))
    done
    
    log_error "Timeout waiting for Vault PVC"
    return 1
}

# Check Vault deployment with enhanced initialization
check_vault_deployment() {
    local timeout="${1:-300}"
    local elapsed=0
    local token_refresh_attempts=0
    local max_token_refresh_attempts=2
    
    log_info "Checking Vault deployment status"
    
    # First wait for PVC
    if ! wait_for_vault_pvc; then
        return 1
    fi
    
    # Wait for pod to be created
    while [ $elapsed -lt $timeout ]; do
        if kubectl get pod -n "$VAULT_NAMESPACE" vault-0 &>/dev/null; then
            local pod_phase=$(kubectl get pod -n "$VAULT_NAMESPACE" vault-0 -o jsonpath='{.status.phase}')
            local containers_ready=$(kubectl get pod -n "$VAULT_NAMESPACE" vault-0 \
                -o jsonpath='{.status.containerStatuses[?(@.name=="vault")].ready}')
            
            if [ "$pod_phase" = "Running" ] && [ "$containers_ready" = "true" ]; then
                log_success "Vault pod is running and ready"
                
                # Wait a bit for Vault to fully initialize
                sleep 10
                
                # Run initialization helper
                if "$SCRIPT_DIR/vault-init-helper.sh"; then
                    log_success "Vault initialized successfully"
                    return 0
                else
                    # If init helper fails, check if it's already initialized
                    if kubectl get secret -n "$VAULT_NAMESPACE" vault-admin-token &>/dev/null && \
                       kubectl get secret -n "$VAULT_NAMESPACE" vault-keys &>/dev/null; then
                        log_warn "Vault initialization had issues but secrets exist"
                        return 0
                    fi
                    log_error "Vault initialization failed"
                    return 1
                fi
            elif [ "$pod_phase" = "Running" ]; then
                log_info "Waiting for Vault container to be ready (init containers may still be running)"
                # Check for common errors in pod logs
                if kubectl logs -n "$VAULT_NAMESPACE" vault-0 --tail=10 2>&1 | grep -q "invalid token\|permission denied"; then
                    # Check if we've tried too many times
                    if [ $token_refresh_attempts -ge $max_token_refresh_attempts ]; then
                        log_error "Exceeded maximum token refresh attempts ($max_token_refresh_attempts)"
                        log_error "Vault failed to start due to invalid transit token!"
                        log_error "Run 'task refresh-transit-token' to get a new token from QNAP Vault"
                        kubectl logs -n "$VAULT_NAMESPACE" vault-0 --tail=5
                        return 1
                    fi
                    
                    token_refresh_attempts=$((token_refresh_attempts + 1))
                    log_warn "Vault failed due to invalid transit token, attempting to refresh (attempt $token_refresh_attempts/$max_token_refresh_attempts)..."
                    
                    # Try to refresh the token automatically
                    if [ -n "$QNAP_VAULT_TOKEN" ] || [ -f "$HOME/.vault-token" ]; then
                        # Set up environment for token refresh
                        export VAULT_ADDR="http://192.168.1.42:61200"
                        if [ -n "$QNAP_VAULT_TOKEN" ]; then
                            export VAULT_TOKEN="$QNAP_VAULT_TOKEN"
                        fi
                        
                        # Try to get fresh token from QNAP Vault
                        log_info "Attempting to retrieve fresh transit token from QNAP Vault..."
                        NEW_TOKEN=$(vault kv get -field=token secret/k8s-transit 2>/dev/null || echo "")
                        
                        if [ -n "$NEW_TOKEN" ] && [ "$NEW_TOKEN" != "" ]; then
                            log_success "Retrieved fresh transit token from QNAP Vault"
                            
                            # Update the secret
                            kubectl delete secret vault-transit-token -n "$VAULT_NAMESPACE" --ignore-not-found=true
                            kubectl create secret generic vault-transit-token \
                                -n "$VAULT_NAMESPACE" \
                                --from-literal=token="$NEW_TOKEN"
                            
                            # Delete the pod to force restart with new token
                            log_info "Restarting Vault pod with new token..."
                            kubectl delete pod vault-0 -n "$VAULT_NAMESPACE" --force --grace-period=0
                            
                            # Wait a bit for pod to be recreated
                            sleep 10
                            
                            # Continue the loop to check again
                            elapsed=$((elapsed + 10))
                            continue
                        else
                            log_error "Failed to retrieve transit token from QNAP Vault"
                            log_error "Please ensure QNAP_VAULT_TOKEN is set or you're authenticated to QNAP Vault"
                        fi
                    fi
                    
                    # If we couldn't auto-refresh, show manual instructions
                    log_error "Vault failed to start due to invalid transit token!"
                    log_error "Run 'task refresh-transit-token' to get a new token from QNAP Vault"
                    kubectl logs -n "$VAULT_NAMESPACE" vault-0 --tail=5
                    return 1
                fi
            else
                log_info "Vault pod status: $pod_phase"
            fi
        fi
        
        sleep 10
        ((elapsed+=10))
    done
    
    log_error "Timeout waiting for Vault deployment"
    return 1
}

# Monitor sync completion
monitor_sync() {
    local app_name="${1}"
    local timeout="${2:-600}"
    local elapsed=0
    
    log_info "Monitoring $app_name sync progress"
    
    while [ $elapsed -lt $timeout ]; do
        local sync_status=$(kubectl get app -n "$ARGOCD_NAMESPACE" "$app_name" \
            -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
        local health_status=$(kubectl get app -n "$ARGOCD_NAMESPACE" "$app_name" \
            -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
        local op_phase=$(kubectl get app -n "$ARGOCD_NAMESPACE" "$app_name" \
            -o jsonpath='{.status.operationState.phase}' 2>/dev/null || echo "")
        
        if [ "$sync_status" = "Synced" ]; then
            log_success "$app_name synced successfully (Health: $health_status)"
            return 0
        elif [ "$sync_status" = "OutOfSync" ] && [ "$op_phase" != "Running" ]; then
            # Check if Vault resources exist
            if kubectl get pod -n "$VAULT_NAMESPACE" vault-0 &>/dev/null; then
                log_success "$app_name resources deployed (Sync: $sync_status, Health: $health_status)"
                return 0
            fi
        elif [ "$sync_status" = "OutOfSync" ] && [ "$health_status" = "Progressing" ]; then
            # Vault may stay OutOfSync temporarily while operator configures post-unseal settings
            if kubectl get pod -n "$VAULT_NAMESPACE" vault-0 &>/dev/null; then
                # Check if pod is actually running
                local pod_phase=$(kubectl get pod -n "$VAULT_NAMESPACE" vault-0 -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                if [ "$pod_phase" = "Running" ]; then
                    log_success "$app_name resources deployed and running (Sync: $sync_status, Health: $health_status)"
                    return 0
                fi
            fi
        elif [ "$op_phase" = "Failed" ] || [ "$op_phase" = "Error" ]; then
            local error_msg=$(kubectl get app -n "$ARGOCD_NAMESPACE" "$app_name" \
                -o jsonpath='{.status.operationState.message}' 2>/dev/null || echo "No error message")
            log_error "Sync failed: $error_msg"
            return 1
        fi
        
        log_info "Status - Sync: $sync_status, Health: $health_status, Operation: $op_phase"
        
        sleep 10
        ((elapsed+=10))
    done
    
    log_error "Timeout waiting for sync completion"
    return 1
}

# Main execution
main() {
    log_info "Starting Vault synchronization (Enhanced)"
    
    # Get transit token
    K8S_VAULT_TRANSIT_TOKEN=$(read_transit_token) || {
        log_error "Failed to obtain transit token"
        cat >&2 <<EOF

To deploy, you need to provide the transit token via one of:
1. Pass as second argument: $0 /path/to/kubeconfig <transit-token>
2. Export K8S_VAULT_TRANSIT_TOKEN environment variable
3. Ensure transit token exists in ../.task/.homelab-deploy-env
4. Export QNAP_VAULT_TOKEN and ensure connectivity to QNAP Vault
5. Run 'task nas:vault-transit' to set up tokens
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
    
    # Sync Vault with retry
    if ! sync_app "vault"; then
        log_error "Failed to initiate Vault sync after retries"
        exit 1
    fi
    
    # Monitor sync completion
    if ! monitor_sync "vault"; then
        log_error "Vault sync failed"
        exit 1
    fi
    
    # Check deployment and initialize
    if ! check_vault_deployment; then
        log_error "Vault deployment failed"
        exit 1
    fi
    
    log_success "Vault synchronization complete"
    log_info "Vault is initialized and ready for use"
}

# Run main function
main "$@"