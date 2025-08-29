#!/bin/bash
set -e

# Initialize Vault and set up transit for Kubernetes unsealing

export VAULT_ADDR=http://192.168.1.42:8200

echo "🔐 Initializing Vault..."
vault operator init -key-shares=1 -key-threshold=1 > vault-keys.txt

echo "🔓 Unsealing Vault..."
UNSEAL_KEY=$(grep "Unseal Key" vault-keys.txt | awk '{print $4}')
ROOT_TOKEN=$(grep "Initial Root Token" vault-keys.txt | awk '{print $4}')

vault operator unseal $UNSEAL_KEY

echo "🔑 Logging in..."
export VAULT_TOKEN=$ROOT_TOKEN

echo "🚂 Setting up transit engine for Kubernetes auto-unseal..."
vault secrets enable transit
vault write -f transit/keys/autounseal

# Create policy for Kubernetes Vault
vault policy write autounseal - <<EOF
path "transit/encrypt/autounseal" {
   capabilities = [ "update" ]
}

path "transit/decrypt/autounseal" {
   capabilities = [ "update" ]
}
EOF

# Create long-lived token for Kubernetes
KUBERNETES_TOKEN=$(vault token create -policy="autounseal" -ttl=8760h -format=json | jq -r '.auth.client_token')

echo ""
echo "✅ Vault initialized and configured!"
echo ""
echo "🔑 Save these values securely:"
echo "Unseal Key: $UNSEAL_KEY"
echo "Root Token: $ROOT_TOKEN"
echo ""
echo "🚂 Transit token for Kubernetes Vault:"
echo "$KUBERNETES_TOKEN"
echo ""
echo "Create the Kubernetes secret with:"
echo "kubectl create secret generic vault-transit-token \\"
echo "  --namespace=vault \\"
echo "  --from-literal=token='$KUBERNETES_TOKEN'"