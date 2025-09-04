#!/bin/bash
# validate-vault-setup.sh - Validate complete Vault setup

set -euo pipefail

# Source health check functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/vault-health-check.sh"

echo "🔍 Validating Vault Setup"
echo "========================="
echo ""

# Track validation results
declare -A validation_results
validation_passed=true

# Validation functions
validate_step() {
    local step_name="$1"
    local step_function="$2"
    
    echo "🔸 Validating: $step_name"
    if $step_function; then
        validation_results["$step_name"]="✅ PASSED"
    else
        validation_results["$step_name"]="❌ FAILED"
        validation_passed=false
    fi
    echo ""
}

# Validation steps
validate_vault_health() {
    check_vault_health 5
}

validate_admin_token() {
    if [ -f /vault-admin-token/token ]; then
        verify_admin_token
    else
        # Try from Kubernetes secret
        local token=$(kubectl get secret vault-admin-token -n vault -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || echo "")
        if [ -n "$token" ]; then
            export VAULT_TOKEN="$token"
            vault token lookup >/dev/null 2>&1
        else
            return 1
        fi
    fi
}

validate_kv_engine() {
    check_secret_engine "secret" "kv" "2"
}

validate_kubernetes_auth() {
    check_auth_method "kubernetes" "kubernetes" || return 1
    
    # Check ESO auth specifically
    if check_auth_method "kubernetes-eso" "kubernetes"; then
        log_success "ESO Kubernetes auth configured"
    else
        log_warning "ESO Kubernetes auth not found"
    fi
    
    return 0
}

validate_essential_secrets() {
    echo "  Checking essential secret paths..."
    
    local essential_paths=(
        "secret/client-ca"
        "secret/ovh-dns"
        "secret/nfs"
    )
    
    local missing=0
    for path in "${essential_paths[@]}"; do
        if vault kv get "$path" >/dev/null 2>&1; then
            echo "    ✓ $path exists"
        else
            echo "    ✗ $path missing"
            ((missing++))
        fi
    done
    
    if [ $missing -eq 0 ]; then
        log_success "All essential secrets present"
        return 0
    else
        log_warning "$missing essential secrets missing"
        return 1
    fi
}

validate_policies() {
    echo "  Checking Vault policies..."
    
    local policies=$(vault policy list 2>/dev/null || echo "")
    local required_policies=(
        "default"
        "haproxy-ingress"
    )
    
    local missing=0
    for policy in "${required_policies[@]}"; do
        if echo "$policies" | grep -q "^${policy}$"; then
            echo "    ✓ Policy '$policy' exists"
        else
            echo "    ✗ Policy '$policy' missing"
            ((missing++))
        fi
    done
    
    if [ $missing -eq 0 ]; then
        log_success "All required policies present"
        return 0
    else
        log_warning "$missing required policies missing"
        return 1
    fi
}

validate_kv_operations() {
    test_kv_operations "secret"
}

# Main validation
main() {
    # Set Vault address if not set
    export VAULT_ADDR="${VAULT_ADDR:-http://vault.vault.svc.cluster.local:8200}"
    export VAULT_SKIP_VERIFY=true
    
    # Run all validations
    validate_step "Vault Health" validate_vault_health
    validate_step "Admin Token" validate_admin_token
    validate_step "KV Engine" validate_kv_engine
    validate_step "Kubernetes Auth" validate_kubernetes_auth
    validate_step "Essential Secrets" validate_essential_secrets
    validate_step "Policies" validate_policies
    validate_step "KV Operations" validate_kv_operations
    
    # Summary
    echo "📊 Validation Summary"
    echo "===================="
    for step in "${!validation_results[@]}"; do
        echo "  ${validation_results[$step]} - $step"
    done
    echo ""
    
    if [ "$validation_passed" = "true" ]; then
        log_success "All validations passed! Vault is properly configured."
        exit 0
    else
        log_error "Some validations failed. Please check the logs above."
        exit 1
    fi
}

# Check if we have required tools
if ! command -v jq >/dev/null 2>&1; then
    echo "Installing jq..."
    apk add --no-cache jq >/dev/null 2>&1 || {
        log_error "Failed to install jq"
        exit 1
    }
fi

# Run main
main "$@"