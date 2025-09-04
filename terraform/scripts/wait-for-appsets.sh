#!/bin/bash
set -e

# Parameters
KUBECONFIG="${1:?Error: KUBECONFIG path required as first argument}"
export KUBECONFIG

echo "⏳ Waiting for ApplicationSets to generate applications..."

# Wait for specific apps to be created by ApplicationSets
apps="vault cert-manager external-secrets-operator stakater-reloader rook-ceph"
for app in $apps; do
  echo "🔍 Waiting for $app application..."
  timeout 120s sh -c "until kubectl get app -n argocd $app >/dev/null 2>&1; do
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