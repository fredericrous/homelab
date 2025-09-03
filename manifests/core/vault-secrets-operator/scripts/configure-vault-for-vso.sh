#!/bin/bash
# configure-vault-for-vso.sh - Configure Vault for Vault Secrets Operator
#
# This script sets up Vault with the necessary policies and Kubernetes auth
# configuration for the Vault Secrets Operator (VSO) to function properly.

set -euo pipefail

# Configuration
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VSO_NAMESPACE="${VSO_NAMESPACE:-vault-secrets-operator}"
VAULT_ADDR="${VAULT_ADDR:-http://vault.vault.svc.cluster.local:8200}"
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
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if kubectl get pod -n "$VAULT_NAMESPACE" vault-0 -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Running"; then
            log_info "Vault is running"
            
            # Additional check to ensure Vault is actually ready
            if kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault status &>/dev/null; then
                log_info "Vault is responding to requests"
                return 0
            fi
        fi
        echo "Waiting for Vault... ($attempt/$max_attempts)"
        sleep 5
        ((attempt++))
    done
    
    log_error "Timeout waiting for Vault to be ready"
    return 1
}

get_vault_token() {
    echo "🔑 Retrieving Vault admin token..."
    
    if ! kubectl get secret -n "$VAULT_NAMESPACE" vault-admin-token &>/dev/null; then
        log_error "Vault admin token secret not found!"
        echo "Please ensure Vault is initialized and the admin token secret exists."
        return 1
    fi
    
    VAULT_TOKEN=$(kubectl get secret -n "$VAULT_NAMESPACE" vault-admin-token -o jsonpath='{.data.token}' | base64 -d)
    export VAULT_TOKEN
    
    # Validate token
    if vault token lookup &>/dev/null; then
        log_info "Vault token is valid"
        return 0
    else
        log_error "Vault token is invalid"
        return 1
    fi
}

check_kubernetes_auth() {
    echo "🔍 Checking Kubernetes auth configuration..."
    
    if vault auth list | grep -q "kubernetes/"; then
        log_info "Kubernetes auth is already enabled"
        return 0
    else
        log_warn "Kubernetes auth is not enabled"
        return 1
    fi
}

create_vso_policy() {
    echo "📝 Creating VSO policy..."
    
    vault policy write vso - <<'EOF'
# Allow VSO to read all secrets
path "secret/data/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/*" {
  capabilities = ["list", "read"]
}

# Allow authentication
path "auth/kubernetes/login" {
  capabilities = ["create", "update"]
}

# Allow to check authentication configuration
path "auth/kubernetes/role/*" {
  capabilities = ["read", "list"]
}
path "sys/auth" {
  capabilities = ["read"]
}
EOF
    
    log_info "VSO policy created"
}

check_existing_role() {
    local role_name=$1
    
    if vault read "auth/kubernetes/role/$role_name" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

create_vso_auth_role() {
    local role_name="vault-secrets-operator"
    
    echo "🔐 Configuring Kubernetes auth role for VSO..."
    
    # Check if role already exists
    if check_existing_role "$role_name"; then
        log_warn "Role '$role_name' already exists. Updating..."
    fi
    
    vault write "auth/kubernetes/role/$role_name" \
        bound_service_account_names=vault-secrets-operator-controller-manager \
        bound_service_account_namespaces="$VSO_NAMESPACE" \
        policies=vso \
        ttl=24h
    
    log_info "Kubernetes auth role '$role_name' configured"
}

verify_configuration() {
    echo "🔍 Verifying configuration..."
    
    # Check policy exists
    if vault policy read vso &>/dev/null; then
        log_info "VSO policy exists"
    else
        log_error "VSO policy not found"
        return 1
    fi
    
    # Check role exists
    if check_existing_role "vault-secrets-operator"; then
        log_info "VSO auth role exists"
    else
        log_error "VSO auth role not found"
        return 1
    fi
    
    # Show configuration summary
    echo ""
    echo "📋 Configuration Summary:"
    echo "   - Vault Address: $VAULT_ADDR"
    echo "   - VSO Namespace: $VSO_NAMESPACE"
    echo "   - Policy: vso"
    echo "   - Auth Role: vault-secrets-operator"
    echo "   - Service Account: vault-secrets-operator-controller-manager"
}

# Main execution
main() {
    echo "🚀 Configuring Vault for Vault Secrets Operator"
    echo "============================================="
    
    # Wait for Vault to be ready
    wait_for_vault || exit 1
    
    # Get Vault admin token
    get_vault_token || exit 1
    
    # Check if Kubernetes auth is enabled
    if ! check_kubernetes_auth; then
        log_error "Kubernetes auth is not enabled in Vault"
        echo "Please ensure Kubernetes auth is configured before running this script."
        echo "This should have been done by the Vault initialization process."
        exit 1
    fi
    
    # Create VSO policy
    create_vso_policy
    
    # Create Kubernetes auth role
    create_vso_auth_role
    
    # Verify configuration
    verify_configuration || exit 1
    
    log_info "Vault configured successfully for VSO!"
}

# Run main function
main