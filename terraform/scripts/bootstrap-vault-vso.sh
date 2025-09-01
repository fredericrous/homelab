#!/bin/bash
set -e

KUBECONFIG="${1:?Error: KUBECONFIG path required as first argument}"
export KUBECONFIG

echo "🔐 Bootstrapping Vault and VSO before ArgoCD apps..."

# Step 1: Install VSO CRDs
echo "📦 Installing VSO CRDs..."
kubectl apply -f https://raw.githubusercontent.com/hashicorp/vault-secrets-operator/v0.10.0/chart/crds/secrets.hashicorp.com_vaultauths.yaml
kubectl apply -f https://raw.githubusercontent.com/hashicorp/vault-secrets-operator/v0.10.0/chart/crds/secrets.hashicorp.com_vaultconnections.yaml
kubectl apply -f https://raw.githubusercontent.com/hashicorp/vault-secrets-operator/v0.10.0/chart/crds/secrets.hashicorp.com_vaultstaticsecrets.yaml
echo "✅ VSO CRDs installed"

# Step 2: Deploy Vault directly (not via ArgoCD)
echo "🔐 Deploying Vault..."
kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -

# Check if transit token exists or needs to be created
if ! kubectl get secret vault-transit-token -n vault >/dev/null 2>&1; then
    if [ -n "$QNAP_VAULT_TOKEN" ]; then
        echo "🔑 Creating transit token from QNAP_VAULT_TOKEN..."
        # This will be created by the automated task
    else
        echo "⚠️  No transit token found. It will be created during deployment."
    fi
fi

# Apply Vault manifests directly
echo "📦 Applying Vault manifests..."
kubectl apply -k manifests/core/vault/

# Wait for Vault to be ready
echo "⏳ Waiting for Vault pod..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=vault -n vault --timeout=300s || true

# Step 3: Check Vault initialization
echo "🔍 Checking Vault status..."
for i in {1..30}; do
    if kubectl get secret vault-admin-token -n vault >/dev/null 2>&1; then
        echo "✅ Vault initialized"
        break
    fi
    echo "Waiting for Vault initialization... ($i/30)"
    sleep 10
done

# Step 4: Deploy VSO
echo "🔐 Deploying VSO..."
kubectl create namespace vault-secrets-operator-system --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -k manifests/core/vault-secrets-operator/

echo "⏳ Waiting for VSO..."
kubectl wait --for=condition=Available deployment -l app.kubernetes.io/name=vault-secrets-operator -n vault-secrets-operator-system --timeout=300s

echo "✅ Vault and VSO bootstrap complete!"
echo ""
echo "ArgoCD can now deploy apps that depend on VSO CRDs."