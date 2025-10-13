#!/bin/bash
# Setup Vault transit unseal for main K8s cluster

set -euo pipefail

echo "🔧 Setting up Vault Transit Unseal for Kubernetes..."

# Enable transit engine if not already enabled
if ! vault secrets list | grep -q "^transit/"; then
  echo "📦 Enabling transit secrets engine..."
  vault secrets enable transit
else
  echo "✅ Transit secrets engine already enabled"
fi

# Create encryption key for auto-unseal
echo "🔑 Creating/updating transit key for auto-unseal..."
vault write -f transit/keys/autounseal || echo "Key already exists"

# Create comprehensive policy for K8s Vault
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

# Clean up old tokens
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
echo "   ${K8S_TOKEN}"
echo ""
echo "The token has been:"
echo "  - Stored in Vault at: secret/k8s-transit"
echo "  - Written to: /tmp/k8s-vault-transit-token"
