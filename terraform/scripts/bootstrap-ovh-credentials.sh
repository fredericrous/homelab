#!/bin/bash
# Bootstrap OVH credentials using QNAP Vault
set -e

echo "🔧 Bootstrapping OVH credentials from QNAP Vault"
echo "=============================================="

# Check if cert-manager namespace exists
if ! kubectl get ns cert-manager &>/dev/null 2>&1; then
    echo "📦 Creating cert-manager namespace..."
    kubectl create namespace cert-manager
fi

# Check if QNAP Vault has OVH credentials
export VAULT_ADDR=http://192.168.1.42:61200
export VAULT_TOKEN="${QNAP_VAULT_TOKEN:-}"

if [ -z "$VAULT_TOKEN" ]; then
    echo "❌ QNAP_VAULT_TOKEN not set. Please set it first."
    echo "   Get it from: kubectl get secret vault-admin-token -n vault -o jsonpath='{.data.token}' | base64 -d"
    echo "   (Run this on QNAP K3s cluster)"
    exit 1
fi

# Check if OVH credentials exist in QNAP Vault
if vault kv get secret/ovh-dns &>/dev/null 2>&1; then
    echo "✅ Found OVH credentials in QNAP Vault"
    
    # Get the credentials
    APP_KEY=$(vault kv get -field=applicationKey secret/ovh-dns)
    APP_SECRET=$(vault kv get -field=applicationSecret secret/ovh-dns)
    CONSUMER_KEY=$(vault kv get -field=consumerKey secret/ovh-dns)
    
    # Create the secret in cert-manager namespace
    kubectl create secret generic ovh-credentials \
        --namespace=cert-manager \
        --from-literal=applicationKey="$APP_KEY" \
        --from-literal=applicationSecret="$APP_SECRET" \
        --from-literal=consumerKey="$CONSUMER_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    echo "✅ OVH credentials created in cert-manager namespace"
else
    echo "❌ OVH credentials not found in QNAP Vault at secret/ovh-dns"
    echo "   Please add them first:"
    echo "   vault kv put secret/ovh-dns \\"
    echo "     applicationKey=<key> \\"
    echo "     applicationSecret=<secret> \\"
    echo "     consumerKey=<consumer-key>"
    exit 1
fi

echo ""
echo "✅ Bootstrap complete! The main Vault can now deploy successfully."