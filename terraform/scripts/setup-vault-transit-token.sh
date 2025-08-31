#!/bin/bash
set -e

# Parameters
KUBECONFIG="${1:?Error: KUBECONFIG path required as first argument}"
export KUBECONFIG

echo "🔐 Setting up Vault Transit Token for auto-unseal..."

# Check if QNAP Vault is accessible
QNAP_VAULT_ADDR="http://192.168.1.42:8200"
if ! curl -s $QNAP_VAULT_ADDR/v1/sys/health > /dev/null 2>&1; then
    echo "❌ QNAP Vault is not accessible at $QNAP_VAULT_ADDR"
    echo "   Please ensure QNAP Vault is running and accessible"
    exit 1
fi

# Check if we have the transit token
if [ -z "$K8S_VAULT_TRANSIT_TOKEN" ]; then
    echo "❌ K8S_VAULT_TRANSIT_TOKEN environment variable not set"
    echo ""
    echo "To set up the transit token:"
    echo "1. SSH to QNAP and run:"
    echo "   cd /share/VMs/homelab/nas"
    echo "   ./vault/scripts/init-and-setup-transit.sh"
    echo ""
    echo "2. Copy the generated token and run:"
    echo "   export K8S_VAULT_TRANSIT_TOKEN=<token-from-script>"
    echo ""
    echo "3. Re-run this script"
    exit 1
fi

# Create the namespace if it doesn't exist
echo "📦 Creating Vault namespace..."
kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -

# Create the transit token secret
echo "🔑 Creating transit token secret..."
kubectl create secret generic vault-transit-token \
    --namespace=vault \
    --from-literal=token="$K8S_VAULT_TRANSIT_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "✅ Vault transit token configured successfully!"
echo ""
echo "ℹ️  Vault will now auto-unseal using QNAP Vault when deployed"