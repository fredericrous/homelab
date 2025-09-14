#!/bin/bash
set -e

# Parameters
KUBECONFIG="${1:?Error: KUBECONFIG path required as first argument}"
export KUBECONFIG

echo "⏳ Waiting for ApplicationSets to generate applications..."

# First, check if ArgoCD server is healthy
echo "🔍 Checking ArgoCD server health..."
if ! kubectl wait --for=condition=available --timeout=30s deployment/argocd-server -n argocd >/dev/null 2>&1; then
  echo "⚠️  ArgoCD server is not healthy, checking logs..."
  kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=10 || true
  echo ""
  echo "⚠️  ArgoCD server may have configuration issues. Run ./scripts/fix-argocd-env-vars.sh to fix."
  exit 1
fi

# Wait for specific apps to be created by ApplicationSets
apps="vault cert-manager external-secrets-operator stakater-reloader rook-ceph"
KUBECONFIG_PATH="$KUBECONFIG"
for app in $apps; do
  echo "🔍 Waiting for $app application..."
  timeout 120s sh -c "export KUBECONFIG='$KUBECONFIG_PATH'; until kubectl get app -n argocd $app >/dev/null 2>&1; do
    sleep 2
  done"
  
  if [ $? -eq 0 ]; then
    echo "✅ $app application created"
  else
    echo "⚠️  Warning: $app application not found after timeout"
  fi
done

echo "📋 Current applications:"
kubectl get app -n argocd --no-headers | awk '{print "  - " $1}'

echo "✅ Proceeding with core services bootstrap"