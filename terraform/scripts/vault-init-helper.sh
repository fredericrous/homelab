#!/bin/bash
# vault-init-helper.sh - Helper script to wait for Vault initialization
# Now relies on vault-transit-unseal-operator for actual initialization

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

# Wait for Vault to be ready and initialized
wait_for_vault() {
    local elapsed=0

    log_info "Waiting for Vault pod to be ready..."
    while [ $elapsed -lt $MAX_WAIT ]; do
        if kubectl get pod -n "$VAULT_NAMESPACE" vault-0 &>/dev/null; then
            local phase=$(kubectl get pod -n "$VAULT_NAMESPACE" vault-0 -o jsonpath='{.status.phase}')
            local ready=$(kubectl get pod -n "$VAULT_NAMESPACE" vault-0 -o jsonpath='{.status.containerStatuses[?(@.name=="vault")].ready}')

            if [ "$phase" = "Running" ] && [ "$ready" = "true" ]; then
                log_info "Vault pod is ready"
                break
            fi
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [ $elapsed -ge $MAX_WAIT ]; then
        log_error "Timeout waiting for Vault pod"
        return 1
    fi

    # Give Vault a moment to fully start
    log_info "Waiting for Vault to be fully ready..."
    sleep 10

    # Wait for vault-transit-unseal-operator to initialize Vault
    log_info "Waiting for vault-transit-unseal-operator to initialize Vault..."
    elapsed=0
    while [ $elapsed -lt $MAX_WAIT ]; do
        local status_output
        if status_output=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -c vault -- vault status 2>&1); then
            if echo "$status_output" | grep -q "Initialized.*true"; then
                log_info "Vault is initialized"

                # Verify admin token exists
                if kubectl get secret -n "$VAULT_NAMESPACE" vault-admin-token &>/dev/null; then
                    log_info "Admin token secret exists"

                    # Verify Vault is unsealed
                    if echo "$status_output" | grep -q "Sealed.*false"; then
                        log_info "Vault is unsealed"
                        return 0
                    else
                        log_warn "Vault is sealed - transit unseal should handle this"
                    fi
                    return 0
                else
                    log_warn "Waiting for admin token secret to be created by vault-transit-unseal-operator..."
                fi
            fi
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [ $elapsed -ge $MAX_WAIT ]; then
        log_error "Timeout waiting for Vault initialization"
        log_error "Check vault-transit-unseal-operator logs: kubectl logs -n vault-transit-unseal-operator deployment/vault-transit-unseal-operator"
        return 1
    fi
}

# Main execution
main() {
    export KUBECONFIG

    if ! wait_for_vault; then
        log_error "Vault initialization check failed"
        return 1
    fi

    log_info "Vault is ready and initialized!"
    return 0
}

main "$@"
