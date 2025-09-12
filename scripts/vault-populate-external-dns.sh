#!/bin/bash
set -euo pipefail

echo "🔐 Populating External-DNS OVH credentials in Vault..."

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl not found"
    exit 1
fi

# Check if vault CLI is available
if ! command -v vault &> /dev/null; then
    echo "❌ vault CLI not found"
    exit 1
fi

# Check environment variables
if [ -z "${EXTERNAL_DNS_OVH_APPLICATION_KEY:-}" ]; then
    echo "❌ EXTERNAL_DNS_OVH_APPLICATION_KEY not set"
    exit 1
fi

if [ -z "${EXTERNAL_DNS_OVH_APPLICATION_SECRET:-}" ]; then
    echo "❌ EXTERNAL_DNS_OVH_APPLICATION_SECRET not set"
    exit 1
fi

if [ -z "${EXTERNAL_DNS_OVH_CONSUMER_KEY:-}" ]; then
    echo "❌ EXTERNAL_DNS_OVH_CONSUMER_KEY not set"
    exit 1
fi

# Setup Vault connection
if [ -z "${VAULT_ADDR:-}" ]; then
    echo "🔗 Setting up Vault connection..."
    kubectl port-forward -n vault svc/vault 8200:8200 &
    PF_PID=$!
    sleep 3
    export VAULT_ADDR=http://127.0.0.1:8200
fi

# Get Vault token if not set
if [ -z "${VAULT_TOKEN:-}" ]; then
    echo "🔑 Getting Vault token..."
    export VAULT_TOKEN=$(kubectl get secret vault-admin-token -n vault -o jsonpath='{.data.token}' | base64 -d)
fi

# Check if credentials already exist
if vault kv get secret/external-dns/ovh >/dev/null 2>&1; then
    echo "⚠️  External-DNS OVH credentials already exist in Vault"
    echo "   Updating with new credentials..."
fi

# Create/Update the secret
echo "💾 Writing External-DNS OVH credentials to Vault..."
vault kv put secret/external-dns/ovh \
    applicationKey="$EXTERNAL_DNS_OVH_APPLICATION_KEY" \
    applicationSecret="$EXTERNAL_DNS_OVH_APPLICATION_SECRET" \
    consumerKey="$EXTERNAL_DNS_OVH_CONSUMER_KEY"

echo "✅ External-DNS OVH credentials stored successfully"

# Cleanup port-forward if we started it
if [ -n "${PF_PID:-}" ]; then
    kill $PF_PID 2>/dev/null || true
fi

echo ""
echo "💡 Next steps:"
echo "   1. Restart external-dns pod to pick up new credentials"
echo "   2. Check logs: kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns"