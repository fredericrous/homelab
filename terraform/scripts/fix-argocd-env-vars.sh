#!/bin/bash
set -e

KUBECONFIG="${1:-$HOME/Developer/Perso/homelab/kubeconfig}"
export KUBECONFIG

echo "🔧 Fixing ArgoCD environment variables..."

# Load external domain from temporary global-config.yaml
if [ -f "$(dirname "$0")/../../.global-config.yaml.tmp" ]; then
  EXTERNAL_DOMAIN=$(yq '.defaultExternalDomain' "$(dirname "$0")/../../.global-config.yaml.tmp")
  echo "Loaded external domain from temporary global-config.yaml"
else
  echo "ERROR: .global-config.yaml.tmp not found - ensure sync_global_config has run"
  exit 1
fi

# Verify the external domain is loaded
if [ -z "$EXTERNAL_DOMAIN" ]; then
  echo "ERROR: External domain not found!"
  exit 1
fi

echo "Using external domain: $EXTERNAL_DOMAIN"

# Get the current ArgoCD ConfigMap and substitute variables
echo "📝 Patching ArgoCD ConfigMap..."
kubectl get cm argocd-cm -n argocd -o yaml | \
  sed -e "s/\${ARGO_EXTERNAL_DOMAIN}/$EXTERNAL_DOMAIN/g" -e "s/PLACEHOLDER_EXTERNAL_DOMAIN/$EXTERNAL_DOMAIN/g" | \
  kubectl apply -f -

# Restart ArgoCD server to pick up the changes
echo "🔄 Restarting ArgoCD server..."
kubectl rollout restart deployment/argocd-server -n argocd

# Wait for ArgoCD server to be ready
echo "⏳ Waiting for ArgoCD server to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

echo "✅ ArgoCD environment variables fixed!"

# Check if ApplicationSets exist
echo "🔍 Checking for ApplicationSets..."
kubectl get applicationsets -n argocd

# If no ApplicationSets, apply them manually
if ! kubectl get applicationsets -n argocd 2>/dev/null | grep -q "core\|apps"; then
  echo "📦 ApplicationSets not found, applying them..."
  kubectl apply -f "$(dirname "$0")/../../manifests/argocd/root/applicationset-core.yaml"
  kubectl apply -f "$(dirname "$0")/../../manifests/argocd/root/applicationset-apps.yaml"
  echo "✅ ApplicationSets applied"
fi

echo "✅ Fix complete!"