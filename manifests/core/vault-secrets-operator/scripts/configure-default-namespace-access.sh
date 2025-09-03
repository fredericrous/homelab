#!/bin/bash
# configure-default-namespace-access.sh - Configure Vault access for default namespace
#
# This script sets up Vault policies and Kubernetes auth configuration
# for the default namespace to access SMB credentials.

set -euo pipefail

# Configuration
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
        if vault status &>/dev/null; then
            log_info "Vault is ready"
            return 0
        fi
        echo "Waiting for Vault... ($attempt/$max_attempts)"
        sleep 5
        ((attempt++))
    done
    
    log_error "Timeout waiting for Vault"
    return 1
}

get_vault_token() {
    echo "🔑 Loading Vault admin token..."
    
    if [ -f /vault/admin-token/token ]; then
        VAULT_TOKEN=$(cat /vault/admin-token/token)
        export VAULT_TOKEN
    else
        log_error "Admin token file not found!"
        echo "Expected token at: /vault/admin-token/token"
        return 1
    fi
    
    # Validate token
    if vault token lookup &>/dev/null; then
        log_info "Vault token is valid"
        return 0
    else
        log_error "Vault token is invalid"
        return 1
    fi
}

create_default_policy() {
    echo "📝 Creating policy for default namespace..."
    
    vault policy write default-policy - <<'EOF'
# Allow default namespace to read SMB credentials
path "secret/data/smb" {
  capabilities = ["read"]
}
EOF
    
    log_info "Default namespace policy created"
}

check_existing_role() {
    local role_name=$1
    
    if vault read "auth/kubernetes/role/$role_name" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

create_default_auth_role() {
    local role_name="default"
    
    echo "🔐 Configuring Kubernetes auth role for default namespace..."
    
    # Check if role already exists
    if check_existing_role "$role_name"; then
        log_warn "Role '$role_name' already exists. Updating..."
    fi
    
    vault write "auth/kubernetes/role/$role_name" \
        bound_service_account_names=default \
        bound_service_account_namespaces=default \
        policies=default-policy \
        ttl=24h
    
    log_info "Kubernetes auth role '$role_name' configured"
}

verify_configuration() {
    echo "🔍 Verifying configuration..."
    
    # Check policy exists
    if vault policy read default-policy &>/dev/null; then
        log_info "Default policy exists"
    else
        log_error "Default policy not found"
        return 1
    fi
    
    # Check role exists
    if check_existing_role "default"; then
        log_info "Default auth role exists"
        
        # Show role details
        echo ""
        echo "📋 Role Configuration:"
        vault read auth/kubernetes/role/default || true
    else
        log_error "Default auth role not found"
        return 1
    fi
}

# Main execution
main() {
    echo "🚀 Configuring Vault Access for Default Namespace"
    echo "==============================================="
    
    # Wait for Vault to be ready
    wait_for_vault || exit 1
    
    # Get Vault admin token
    get_vault_token || exit 1
    
    # Create policy
    create_default_policy
    
    # Create Kubernetes auth role
    create_default_auth_role
    
    # Verify configuration
    verify_configuration || exit 1
    
    log_info "Default namespace configured for SMB access!"
}

# Run main function
main