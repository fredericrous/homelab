#!/bin/bash
# Setup bootstrap configuration in NAS Vault for ArgoCD Vault Plugin

set -euo pipefail

echo "🔐 Setting up bootstrap configuration for ArgoCD Vault Plugin..."

# Get script directory and find project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

# Check for .env file
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Error: .env file not found at $ENV_FILE"
    echo "Please ensure .env exists in project root"
    exit 1
fi

echo "📝 Using .env file at: $ENV_FILE"

# Check if Vault is accessible
if ! vault status &>/dev/null; then
    echo "❌ Error: Vault is not accessible"
    echo "Please ensure:"
    echo "  - export VAULT_ADDR=http://192.168.1.42:61200"
    echo "  - vault login <token>"
    exit 1
fi

# Load environment variables
set -a
source "$ENV_FILE"
set +a

# Convert ARGO_ prefixed variables to camelCase and store in Vault
echo "📝 Converting ARGO_ variables from .env to bootstrap config..."

# Build the vault kv put command dynamically
VAULT_CMD="vault kv put secret/bootstrap/config"

# Process all ARGO_ prefixed variables
while IFS='=' read -r key value; do
    # Skip comments and empty lines
    [[ "$key" =~ ^#.*$ ]] || [[ -z "$key" ]] && continue
    
    # Only process ARGO_ prefixed variables
    if [[ "$key" =~ ^ARGO_ ]]; then
        # Remove ARGO_ prefix and convert to camelCase
        # First, remove ARGO_ prefix
        var_name="${key#ARGO_}"
        
        # Convert snake_case to camelCase
        # Split by underscore and process each part
        var_name=$(echo "$var_name" | awk -F_ '{
            # First part is lowercase
            printf "%s", tolower($1)
            # Remaining parts are capitalized
            for(i=2; i<=NF; i++) {
                printf "%s", toupper(substr($i,1,1)) tolower(substr($i,2))
            }
        }')
        
        # Get the value from environment
        var_value="${!key}"
        
        # Skip if value is empty
        [[ -z "$var_value" ]] && continue
        
        # Add to vault command
        VAULT_CMD="$VAULT_CMD $var_name=\"$var_value\""
        
        echo "  $key -> $var_name: $var_value"
    fi
done < "$ENV_FILE"

# Execute the vault command
eval "$VAULT_CMD"

echo "✅ Bootstrap configuration stored at secret/bootstrap/config"
echo ""
echo "📋 Stored variables:"
vault kv get -format=json secret/bootstrap/config | jq -r '.data.data | to_entries[] | "  \(.key): \(.value)"'
echo ""
echo "🚀 Bootstrap configuration is ready for ArgoCD Vault Plugin!"
echo ""
echo "Next steps:"
echo "1. Deploy the main K8s cluster: task deploy"
echo "2. AVP will use these values to configure core services"