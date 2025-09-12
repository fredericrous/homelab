#!/bin/bash
# Bootstrap script to create ConfigMap from .env file

set -euo pipefail

echo "🔄 Creating ArgoCD values ConfigMap from .env..."

# Check if .env exists
if [ ! -f ".env" ]; then
    echo "❌ .env file not found"
    echo "Please copy from homelab-values repository:"
    echo "  cp ../homelab-values/.env .env"
    exit 1
fi

# Create namespace if it doesn't exist
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Filter only ARGO_ prefixed variables for ArgoCD
echo "📝 Filtering ARGO_ prefixed variables..."
grep "^ARGO_" .env > /tmp/argo-values.env || true

# Check if we have any ARGO_ variables
if [ ! -s /tmp/argo-values.env ]; then
    echo "⚠️  No ARGO_ prefixed variables found in .env"
    echo "   Add variables like ARGO_NAS_VAULT_ADDRto use with ArgoCD"
    exit 1
fi

# Create ConfigMap from filtered env file
kubectl create configmap argocd-envsubst-values \
    --from-env-file=/tmp/argo-values.env \
    --namespace=argocd \
    --dry-run=client -o yaml | kubectl apply -f -

# Clean up
rm -f /tmp/argo-values.env

echo "✅ ConfigMap created/updated"

# Show what was created
echo ""
echo "📋 ConfigMap contents:"
kubectl get configmap argocd-envsubst-values -n argocd -o yaml | grep -A20 "^data:" | head -20

echo ""
echo "💡 This ConfigMap will be used by the ArgoCD envsubst plugin"
