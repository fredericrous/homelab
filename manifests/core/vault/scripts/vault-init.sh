#!/bin/bash
# vault-init.sh - Initialize Vault with transit unseal
#
# This script handles Vault initialization with transit unseal via QNAP Vault.
# It's designed to be idempotent and handle various edge cases including:
# - Already initialized Vault
# - Missing admin token recovery
# - Transit token validation
# - Vault 1.20.1 auto-initialization issues

set -euo pipefail

# Configuration
VAULT_ADDR="${VAULT_ADDR:-http://vault:8200}"
export VAULT_ADDR

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${GREEN}✅${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}⚠️${NC}  $1"
}

log_error() {
    echo -e "${RED}❌${NC} $1"
}

wait_for_vault() {
    echo "⏳ Waiting for Vault to be ready..."
    local max_attempts=90
    local attempt=1
    
    # First check if we can reach the service
    echo "Checking Vault connectivity at ${VAULT_ADDR}..."
    
    while [ $attempt -le $max_attempts ]; do
        # Try both vault status and a simple curl to the health endpoint
        if vault status >/dev/null 2>&1; then
            log_info "Vault is responding"
            return 0
        elif curl -s "${VAULT_ADDR}/v1/sys/health" >/dev/null 2>&1; then
            echo "Vault HTTP is reachable, waiting for full initialization..."
            sleep 5
            if vault status >/dev/null 2>&1; then
                log_info "Vault is responding"
                return 0
            fi
        fi
        
        if [ $((attempt % 10)) -eq 0 ]; then
            echo "Still waiting... ($attempt/$max_attempts) - checking connectivity"
            # Debug DNS and network
            nslookup vault.vault.svc.cluster.local || echo "DNS lookup failed"
            curl -v --connect-timeout 2 "${VAULT_ADDR}/v1/sys/health" 2>&1 | grep -E "(Connected|Failed)" || true
        fi
        
        echo "Waiting... ($attempt/$max_attempts)"
        sleep 2
        ((attempt++))
    done
    
    log_error "Vault is not responding after 180 seconds"
    echo "Vault pod status:"
    kubectl get pod vault-0 -n vault -o wide || true
    echo "Vault pod logs (last 20 lines):"
    kubectl logs vault-0 -n vault --tail=20 || true
    return 1
}

check_vault_initialized() {
    if vault status 2>/dev/null | grep -q "Initialized.*true"; then
        log_info "Vault is already initialized"
        return 0
    else
        return 1
    fi
}

check_vault_sealed() {
    if vault status 2>/dev/null | grep -q "Sealed.*false"; then
        log_info "Vault is unsealed"
        return 0
    else
        log_warn "Vault is sealed"
        return 1
    fi
}

wait_for_auto_unseal() {
    echo "⏳ Waiting for transit auto-unseal..."
    sleep 5
    
    if check_vault_sealed; then
        log_info "Vault auto-unsealed via transit"
        return 0
    else
        log_error "Vault remains sealed - check transit configuration"
        return 1
    fi
}

check_admin_token() {
    if kubectl get secret vault-admin-token -n vault &>/dev/null; then
        log_info "Admin token secret exists"
        return 0
    else
        log_warn "Admin token secret missing"
        return 1
    fi
}

recover_admin_token() {
    log_warn "Admin token secret missing - attempting recovery..."
    
    if [ -f /recovery/root-token ]; then
        echo "📂 Found recovery token file"
        local root_token=$(cat /recovery/root-token)
        
        # Test if token is valid
        export VAULT_TOKEN="$root_token"
        if vault token lookup &>/dev/null; then
            log_info "Recovery token is valid"
            
            # Store in secret
            kubectl create secret generic vault-admin-token \
                --namespace=vault \
                --from-literal=token="$root_token" \
                --dry-run=client -o yaml | kubectl apply -f -
            
            log_info "Admin token secret created from recovery"
            return 0
        else
            log_error "Recovery token is invalid"
            return 1
        fi
    else
        log_error "No recovery token available"
        echo ""
        echo "Manual recovery required:"
        echo "1. If you have the root token, create the secret manually:"
        echo "   kubectl create secret generic vault-admin-token -n vault --from-literal=token=<your-root-token>"
        echo ""
        echo "2. Or generate a new root token (requires unseal key):"
        echo "   vault operator generate-root"
        return 1
    fi
}

check_transit_token() {
    if ! kubectl get secret vault-transit-token -n vault &>/dev/null; then
        log_error "Transit token secret missing! Cannot initialize with transit unseal."
        return 1
    fi
    
    local token_value=$(kubectl get secret vault-transit-token -n vault -o jsonpath='{.data.token}' | base64 -d)
    if [ "$token_value" = "PLACEHOLDER_WILL_BE_REPLACED_BY_TERRAFORM" ]; then
        log_error "Transit token has placeholder value! Terraform should have replaced this."
        return 1
    fi
    
    log_info "Transit token secret is configured"
    return 0
}

initialize_vault() {
    echo "🎲 Initializing Vault..."
    
    # Check transit token first
    check_transit_token || return 1
    
    # With transit unseal, we need recovery shares for emergency access
    # Using -key-shares and -key-threshold would create unseal keys, which we don't want
    local init_output
    init_output=$(vault operator init \
        -recovery-shares=5 \
        -recovery-threshold=3 \
        -format=json 2>&1) || {
        log_error "Initialization failed: $init_output"
        
        # Check if it's the auto-initialization issue
        if echo "$init_output" | grep -q "already initialized"; then
            log_warn "Vault auto-initialized without providing keys!"
            echo "    This is a known issue with Vault 1.20.1"
            echo "    Manual intervention required to get root token"
        fi
        return 1
    }
    
    # Extract root token
    local root_token=$(echo "$init_output" | jq -r '.root_token // empty')
    if [ -z "$root_token" ]; then
        log_error "Failed to extract root token from init output"
        echo "Debug output: $init_output"
        return 1
    fi
    
    # Store root token in secret
    kubectl create secret generic vault-admin-token \
        --namespace=vault \
        --from-literal=token="$root_token" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Store all recovery keys for emergency use
    echo "$init_output" | jq -r '.recovery_keys_b64[]' > /tmp/recovery-keys.txt
    kubectl create secret generic vault-recovery-keys \
        --namespace=vault \
        --from-file=recovery-keys=/tmp/recovery-keys.txt \
        --dry-run=client -o yaml | kubectl apply -f -
    rm -f /tmp/recovery-keys.txt
    
    # Also save to recovery location if mounted
    if [ -d /recovery ] && [ -w /recovery ]; then
        echo "$root_token" > /recovery/root-token
        echo "📋 Root token saved to recovery location"
    fi
    
    log_info "Vault initialized successfully!"
    log_info "Root token stored in vault-admin-token secret"
    echo ""
    echo "📋 Note: With transit auto-unseal:"
    echo "   - No manual unseal keys are needed"
    echo "   - Vault will auto-unseal using QNAP Vault"
    echo "   - The root token is stored in the vault-admin-token secret"
}

# Main execution
main() {
    echo "🔐 Initializing Vault with Transit Unseal"
    echo "========================================"
    
    # Wait for Vault to be ready
    wait_for_vault || exit 1
    
    # Check if already initialized
    if check_vault_initialized; then
        # Check if sealed
        if ! check_vault_sealed; then
            wait_for_auto_unseal || exit 1
        fi
        
        # Check if admin token exists
        if ! check_admin_token; then
            recover_admin_token || exit 1
        fi
        
        exit 0
    fi
    
    # Not initialized - initialize it
    initialize_vault || exit 1
}

# Run main function
main