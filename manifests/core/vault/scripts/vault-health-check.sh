#!/bin/bash
# vault-health-check.sh - Common health check functions for Vault jobs

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_error() { echo -e "${RED}❌ $1${NC}" >&2; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_info() { echo "ℹ️  $1"; }

# Check if Vault is healthy (initialized and unsealed)
check_vault_health() {
    local max_attempts=${1:-30}
    local attempt=1
    
    echo "🏥 Performing Vault health checks..."
    
    while [ $attempt -le $max_attempts ]; do
        if vault status >/dev/null 2>&1; then
            local vault_status=$(vault status -format=json)
            local sealed=$(echo "$vault_status" | jq -r '.sealed')
            local initialized=$(echo "$vault_status" | jq -r '.initialized')
            local version=$(echo "$vault_status" | jq -r '.version')
            
            if [ "$initialized" = "true" ] && [ "$sealed" = "false" ]; then
                log_success "Vault v${version} is initialized and unsealed"
                return 0
            elif [ "$sealed" = "true" ]; then
                log_warning "Vault is sealed, waiting for auto-unseal..."
            elif [ "$initialized" = "false" ]; then
                log_warning "Vault not initialized yet..."
            fi
        else
            echo "⏳ Waiting for Vault API... (attempt $attempt/$max_attempts)"
        fi
        
        sleep 5
        ((attempt++))
    done
    
    log_error "Vault health check failed after $max_attempts attempts"
    return 1
}

# Verify admin token is valid
verify_admin_token() {
    local token_file="${1:-/vault-admin-token/token}"
    
    echo "🔑 Verifying admin token..."
    
    if ! [ -f "$token_file" ]; then
        log_error "Admin token file not found at $token_file"
        return 1
    fi
    
    local token=$(cat "$token_file")
    if [ -z "$token" ] || [ "$token" = "temp-token" ] || [ "$token" = "PLACEHOLDER" ]; then
        log_error "Invalid or placeholder admin token"
        return 1
    fi
    
    export VAULT_TOKEN="$token"
    
    # Test token validity
    if ! vault token lookup >/dev/null 2>&1; then
        log_error "Admin token is not valid"
        return 1
    fi
    
    # Check token capabilities
    local token_info=$(vault token lookup -format=json)
    local policies=$(echo "$token_info" | jq -r '.data.policies[]' 2>/dev/null || echo "")
    
    if [[ "$policies" == *"root"* ]]; then
        log_success "Admin token is valid (root access)"
    else
        log_warning "Admin token is valid but not root (policies: $policies)"
    fi
    
    return 0
}

# Wait for a specific Kubernetes resource
wait_for_resource() {
    local resource_type="$1"
    local resource_name="$2"
    local namespace="${3:-default}"
    local max_wait="${4:-300}"
    
    echo "⏳ Waiting for $resource_type/$resource_name in namespace $namespace..."
    
    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        if kubectl get "$resource_type" "$resource_name" -n "$namespace" >/dev/null 2>&1; then
            log_success "$resource_type/$resource_name exists"
            return 0
        fi
        
        echo "   Waiting... ($elapsed/$max_wait seconds)"
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    log_error "Timeout waiting for $resource_type/$resource_name"
    return 1
}

# Check if a Vault secret engine is mounted
check_secret_engine() {
    local mount_path="$1"
    local expected_type="${2:-kv}"
    local expected_version="${3:-2}"
    
    echo "🗄️  Checking secret engine at $mount_path..."
    
    if vault secrets list -format=json | jq -e ".[\"${mount_path}/\"]" >/dev/null 2>&1; then
        local engine_info=$(vault secrets list -format=json | jq ".[\"${mount_path}/\"]")
        local engine_type=$(echo "$engine_info" | jq -r '.type')
        local engine_version=$(echo "$engine_info" | jq -r '.options.version // "1"')
        
        if [ "$engine_type" = "$expected_type" ]; then
            if [ "$expected_type" = "kv" ] && [ "$engine_version" != "$expected_version" ]; then
                log_warning "Found KV v${engine_version} at $mount_path (expected v${expected_version})"
                return 1
            fi
            log_success "$expected_type engine mounted at $mount_path"
            return 0
        else
            log_error "Found $engine_type engine at $mount_path (expected $expected_type)"
            return 1
        fi
    else
        log_info "No secret engine found at $mount_path"
        return 1
    fi
}

# Check if a Vault auth method is enabled
check_auth_method() {
    local auth_path="$1"
    local expected_type="${2:-kubernetes}"
    
    echo "🔐 Checking auth method at $auth_path..."
    
    if vault auth list -format=json | jq -e ".[\"${auth_path}/\"]" >/dev/null 2>&1; then
        local auth_info=$(vault auth list -format=json | jq ".[\"${auth_path}/\"]")
        local auth_type=$(echo "$auth_info" | jq -r '.type')
        
        if [ "$auth_type" = "$expected_type" ]; then
            log_success "$expected_type auth method enabled at $auth_path"
            return 0
        else
            log_error "Found $auth_type auth at $auth_path (expected $expected_type)"
            return 1
        fi
    else
        log_info "No auth method found at $auth_path"
        return 1
    fi
}

# Test KV operations
test_kv_operations() {
    local mount_path="${1:-secret}"
    local test_path="${mount_path}/health-check-$(date +%s)"
    local test_value="test-value-$(date +%s)"
    
    echo "🧪 Testing KV operations at $mount_path..."
    
    # Test write
    echo "  Writing test secret..."
    if ! vault kv put "$test_path" value="$test_value" >/dev/null 2>&1; then
        log_error "Failed to write test secret"
        return 1
    fi
    
    # Test read
    echo "  Reading test secret..."
    local read_value=$(vault kv get -field=value "$test_path" 2>/dev/null || echo "")
    if [ "$read_value" != "$test_value" ]; then
        log_error "Failed to read test secret correctly"
        echo "     Expected: $test_value"
        echo "     Got: $read_value"
        return 1
    fi
    
    # Test metadata
    echo "  Checking secret metadata..."
    if ! vault kv metadata get "$test_path" >/dev/null 2>&1; then
        log_warning "Failed to read secret metadata (non-critical)"
    fi
    
    # Test delete
    echo "  Deleting test secret..."
    if ! vault kv delete "$test_path" >/dev/null 2>&1; then
        log_warning "Failed to delete test secret (non-critical)"
    fi
    
    log_success "KV operations test passed"
    return 0
}

# Export functions for use by other scripts
export -f log_error log_success log_warning log_info
export -f check_vault_health verify_admin_token wait_for_resource
export -f check_secret_engine check_auth_method test_kv_operations