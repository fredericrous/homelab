#!/bin/bash
# vault-init-helper.sh - Helper script for Vault initialization
# This is a refactored, maintainable version focusing on one responsibility

set -euo pipefail

# Configuration
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_ADDR="${VAULT_ADDR:-http://vault.vault.svc.cluster.local:8200}"
MAX_WAIT="${MAX_WAIT:-300}"
KUBECONFIG="${KUBECONFIG}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}✓${NC} $*"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $*" >&2; }
log_error() { echo -e "${RED}✗${NC} $*" >&2; }

# Wait for Vault to be ready
wait_for_vault() {
    local elapsed=0
    
    while [ $elapsed -lt $MAX_WAIT ]; do
        if kubectl get pod -n "$VAULT_NAMESPACE" vault-0 &>/dev/null; then
            local phase=$(kubectl get pod -n "$VAULT_NAMESPACE" vault-0 -o jsonpath='{.status.phase}')
            local ready=$(kubectl get pod -n "$VAULT_NAMESPACE" vault-0 -o jsonpath='{.status.containerStatuses[?(@.name=="vault")].ready}')
            
            if [ "$phase" = "Running" ] && [ "$ready" = "true" ]; then
                log_info "Vault pod is running and ready"
                return 0
            elif [ "$phase" = "Running" ]; then
                log_info "Vault pod is running but not ready yet (init containers may still be running)"
            fi
        fi
        sleep 5
        ((elapsed+=5))
    done
    
    log_error "Timeout waiting for Vault pod"
    return 1
}

# Initialize Vault with transit unseal
initialize_vault() {
    # Wait a bit more to ensure Vault is fully ready
    log_info "Waiting for Vault to be fully ready..."
    sleep 10
    
    # Check if already initialized
    local status_output
    if ! status_output=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -c vault -- vault status 2>&1); then
        if echo "$status_output" | grep -q "Initialized.*true"; then
            log_info "Vault is already initialized"
            
            # Check if admin token exists
            if kubectl get secret -n "$VAULT_NAMESPACE" vault-admin-token &>/dev/null; then
                log_info "Admin token secret exists"
                return 0
            else
                log_warn "Vault initialized but admin token missing"
                log_warn "Manual recovery required - create vault-admin-token secret"
                return 1
            fi
        elif echo "$status_output" | grep -q "Initialized.*false"; then
            log_info "Vault needs initialization"
        else
            log_error "Failed to check Vault status: $status_output"
            return 1
        fi
    fi
    
    log_info "Initializing Vault with transit unseal..."
    
    # Initialize with minimal shares for transit unseal
    local init_output
    if ! init_output=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -c vault -- \
        vault operator init -recovery-shares=1 -recovery-threshold=1 -format=json 2>&1); then
        log_error "Failed to initialize Vault: $init_output"
        return 1
    fi
    
    # Extract tokens and keys
    local root_token=$(echo "$init_output" | jq -r '.root_token')
    local recovery_key=$(echo "$init_output" | jq -r '.recovery_keys_b64[0]')
    
    if [ -z "$root_token" ] || [ "$root_token" = "null" ]; then
        log_error "Failed to extract root token from initialization"
        return 1
    fi
    
    # Create secrets
    kubectl create secret generic vault-admin-token \
        -n "$VAULT_NAMESPACE" \
        --from-literal=token="$root_token" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    kubectl create secret generic vault-keys \
        -n "$VAULT_NAMESPACE" \
        --from-literal=root-token="$root_token" \
        --from-literal=recovery-key="$recovery_key" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_info "Vault initialized successfully"
    log_info "Root token and recovery key stored in secrets"
    
    return 0
}

# Main
main() {
    log_info "Starting Vault initialization helper"
    
    if ! wait_for_vault; then
        exit 1
    fi
    
    if ! initialize_vault; then
        exit 1
    fi
    
    log_info "Vault initialization complete"
}

main "$@"