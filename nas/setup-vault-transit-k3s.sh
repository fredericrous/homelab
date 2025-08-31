#!/bin/bash
set -e

# Script to set up Vault transit unseal for Kubernetes cluster
echo "🔧 Setting up Vault Transit Unseal for Kubernetes..."

# Configuration
VAULT_ADDR=${VAULT_ADDR:-http://192.168.1.42:61200}
export VAULT_ADDR

# Check if Vault is initialized
if ! vault status > /dev/null 2>&1; then
    echo "❌ Vault is not running or not initialized at $VAULT_ADDR"
    echo "   Please initialize Vault first:"
    echo "   vault operator init -key-shares=1 -key-threshold=1"
    exit 1
fi

# Check if already authenticated
if ! vault token lookup > /dev/null 2>&1; then
    echo "❌ Not authenticated to Vault. Please login first:"
    echo "   export VAULT_TOKEN=<your-root-token>"
    echo "   vault login <your-root-token>"
    exit 1
fi

# Enable transit engine if not already enabled
echo "📦 Checking transit secrets engine..."
if ! vault secrets list | grep -q "^transit/"; then
    echo "📦 Enabling transit secrets engine..."
    vault secrets enable transit
else
    echo "✅ Transit secrets engine already enabled"
fi

# Create encryption key for auto-unseal
echo "🔑 Creating/updating transit key for auto-unseal..."
vault write -f transit/keys/autounseal || echo "Key already exists"

# Create comprehensive policy for K8s Vault based on HashiCorp docs
echo "📝 Creating transit unseal policy..."
cat <<EOF | vault policy write k8s-vault-unseal -
# Transit operations for auto-unseal (minimal required permissions)
path "transit/encrypt/autounseal" {
  capabilities = ["update"]
}

path "transit/decrypt/autounseal" {
  capabilities = ["update"]
}

# Key configuration operations
path "transit/keys/autounseal" {
  capabilities = ["read"]
}

# Additional operations for seal migration
path "transit/rewrap/autounseal" {
  capabilities = ["update"]
}

path "transit/datakey/plaintext/autounseal" {
  capabilities = ["update"]
}

# Allow checking if transit is mounted
path "sys/mounts" {
  capabilities = ["read"]
}

path "sys/mounts/transit" {
  capabilities = ["read"]
}
EOF

# Revoke any existing tokens with this display name
echo "🧹 Cleaning up old transit tokens..."
vault list -format=json auth/token/accessors 2>/dev/null | jq -r '.[]' 2>/dev/null | while read accessor; do
    if [ -n "$accessor" ] && vault token lookup -accessor "$accessor" 2>/dev/null | grep -q "k8s-vault-unseal"; then
        vault token revoke -accessor "$accessor" 2>/dev/null || true
    fi
done || echo "No old tokens to clean up"

# Create token for Kubernetes Vault
echo "🎫 Creating token for Kubernetes Vault..."
K8S_TOKEN=$(vault token create \
    -policy=k8s-vault-unseal \
    -display-name="k8s-vault-unseal" \
    -period=8760h \
    -renewable \
    -format=json | jq -r '.auth.client_token')

# Store token in Vault for automated retrieval
echo "💾 Storing transit token in Vault..."
vault kv put secret/k8s-transit token="$K8S_TOKEN" || echo "Failed to store in KV"

# Create a file with the token for easy access
echo "$K8S_TOKEN" > /tmp/k8s-vault-transit-token

echo ""
echo "✅ Transit unseal setup complete!"
echo ""
echo "📋 Generated transit token for Kubernetes Vault:"
echo "   $K8S_TOKEN"
echo ""
echo "The token has been:"
echo "  - Stored in Vault at: secret/k8s-transit"
echo "  - Written to: /tmp/k8s-vault-transit-token"
echo ""
echo "🔐 Use this token in your Terraform deployment:"
echo "   export K8S_VAULT_TRANSIT_TOKEN=\"$K8S_TOKEN\""
echo ""
echo "Or retrieve it later:"
echo "   export K8S_VAULT_TRANSIT_TOKEN=\$(vault kv get -field=token secret/k8s-transit)"