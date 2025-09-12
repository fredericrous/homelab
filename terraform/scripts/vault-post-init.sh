#!/bin/bash
set -e

# Parameters
KUBECONFIG="${1:?Error: KUBECONFIG path required as first argument}"
export KUBECONFIG

echo "🔐 Running Vault post-initialization tasks..."

# Check if Vault is initialized and unsealed
vault_status=$(kubectl exec -n vault vault-0 -- vault status -format=json 2>/dev/null || echo "{}")
if ! echo "$vault_status" | grep -q "initialized.*true"; then
  echo "❌ Vault is not initialized"
  exit 1
fi

if ! echo "$vault_status" | grep -q "sealed.*false"; then
  echo "❌ Vault is sealed"
  exit 1
fi

echo "✅ Vault is initialized and unsealed"

# Check if we have admin token
if ! kubectl get secret -n vault vault-admin-token >/dev/null 2>&1; then
  echo "❌ Vault admin token secret not found"
  echo "   For existing Vault installations, you need to create it manually:"
  echo "   kubectl create secret generic vault-admin-token -n vault --from-literal=token=<your-root-token>"
  exit 1
fi

# Get the admin token
VAULT_TOKEN=$(kubectl get secret vault-admin-token -n vault -o jsonpath='{.data.token}' | base64 -d)
if [ -z "$VAULT_TOKEN" ] || [ "$VAULT_TOKEN" = "temp-token" ]; then
  echo "❌ Invalid or temporary vault token found"
  echo "   Please update the vault-admin-token secret with the actual root token"
  exit 1
fi

# Port forward to Vault
echo "🔗 Setting up port forward to Vault..."
kubectl port-forward -n vault svc/vault 8200:8200 > /dev/null 2>&1 &
PF_PID=$!
sleep 3

# Ensure port forward is cleaned up on exit
trap "kill $PF_PID 2>/dev/null || true" EXIT

export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN

# Ensure the KV secret engine is enabled
echo "🔍 Checking secret mount configuration..."
if ! vault secrets list | grep -q "^secret/"; then
  echo "❌ KV secret engine not found at secret/"
  echo "   This should have been enabled by the vault-transit-unseal-operator"
  echo "   Please check the VaultTransitUnseal resource postUnsealConfig"
  exit 1
fi

# Check if client CA already exists
echo "🔍 Checking for client CA in Vault..."
if vault kv get secret/client-ca >/dev/null 2>&1; then
  echo "✅ Client CA already exists in Vault"
  echo "   ⚠️  Note: CA should now be synced from NAS Vault via External Secrets"
else
  echo "⚠️  Client CA not found in Vault"
  echo "   The CA will be synced from NAS Vault via External Secrets"
  echo "   Make sure to:"
  echo "   1. Deploy NAS cluster first: task nas:deploy"
  echo "   2. Initialize PKI on NAS: task nas:vault-pki"
  echo "   3. Configure ESO sync token in manifests/core/external-secrets-operator/clustersecretstore-nas-vault.yaml"
fi

# Create policies for services that need the client CA
echo "📝 Creating/updating policies..."

# HAProxy ingress policy
cat <<EOF | vault policy write haproxy-ingress -
path "secret/data/client-ca" {
  capabilities = ["read"]
}
EOF
echo "✅ Created haproxy-ingress policy"

# Ensure Kubernetes auth is configured
if ! vault auth list | grep -q "kubernetes/"; then
  echo "❌ Kubernetes auth not enabled in Vault"
  echo "   This should have been enabled by the vault-transit-unseal-operator"
  echo "   Please check the VaultTransitUnseal resource postUnsealConfig"
  exit 1
fi

# Create/update role for HAProxy
echo "🔧 Configuring Kubernetes auth roles..."
vault write auth/kubernetes/role/haproxy-ingress \
  bound_service_account_names=default \
  bound_service_account_namespaces=haproxy-controller \
  policies=haproxy-ingress \
  ttl=24h || {
    echo "❌ Failed to create haproxy-ingress role"
    exit 1
  }

echo "✅ Configured haproxy-ingress role"

# Store OVH credentials if provided
# For cert-manager
if [ -n "$CERT_MANAGER_OVH_APPLICATION_KEY" ] && [ -n "$CERT_MANAGER_OVH_APPLICATION_SECRET" ] && [ -n "$CERT_MANAGER_OVH_CONSUMER_KEY" ]; then
  echo "📤 Storing cert-manager OVH credentials in Vault..."
  vault kv put secret/ovh-dns \
    applicationKey="$CERT_MANAGER_OVH_APPLICATION_KEY" \
    applicationSecret="$CERT_MANAGER_OVH_APPLICATION_SECRET" \
    consumerKey="$CERT_MANAGER_OVH_CONSUMER_KEY" || {
    echo "⚠️  Failed to store cert-manager OVH credentials in Vault"
  }
  echo "✅ Cert-manager OVH credentials stored in Vault"
else
  echo "ℹ️  Cert-manager OVH credentials not provided. Set CERT_MANAGER_OVH_APPLICATION_KEY, CERT_MANAGER_OVH_APPLICATION_SECRET, and CERT_MANAGER_OVH_CONSUMER_KEY to store them."
fi

# For external-dns
if [ -n "$EXTERNAL_DNS_OVH_APPLICATION_KEY" ] && [ -n "$EXTERNAL_DNS_OVH_APPLICATION_SECRET" ] && [ -n "$EXTERNAL_DNS_OVH_CONSUMER_KEY" ]; then
  echo "📤 Storing external-dns OVH credentials in Vault..."
  vault kv put secret/external-dns/ovh \
    applicationKey="$EXTERNAL_DNS_OVH_APPLICATION_KEY" \
    applicationSecret="$EXTERNAL_DNS_OVH_APPLICATION_SECRET" \
    consumerKey="$EXTERNAL_DNS_OVH_CONSUMER_KEY" || {
    echo "⚠️  Failed to store external-dns OVH credentials in Vault"
  }
  echo "✅ External-dns OVH credentials stored in Vault"
else
  echo "ℹ️  External-dns OVH credentials not provided. Set EXTERNAL_DNS_OVH_APPLICATION_KEY, EXTERNAL_DNS_OVH_APPLICATION_SECRET, and EXTERNAL_DNS_OVH_CONSUMER_KEY to store them."
fi

echo "✅ Vault post-initialization tasks completed successfully"