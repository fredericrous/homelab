#!/bin/bash
set -e

# Parameters
KUBECONFIG="${1:?Error: KUBECONFIG path required as first argument}"
export KUBECONFIG

echo "🔒 Waiting for VSO application to be created by ApplicationSet..."
timeout 150s sh -c 'until kubectl get app -n argocd vault-secrets-operator >/dev/null 2>&1; do
  echo "Waiting for VSO application..."
  sleep 5
done'

if [ $? -eq 0 ]; then
  echo "✅ VSO application found"
else
  echo "❌ Timeout waiting for VSO application"
  exit 1
fi

echo "🔒 Syncing Vault Secrets Operator..."
# Create namespace if it doesn't exist
kubectl create namespace vault-secrets-operator-system --dry-run=client -o yaml | kubectl apply -f -

# Force sync VSO app - Helm will handle CRDs with installCRDs=true
kubectl patch app -n argocd vault-secrets-operator --type merge -p '{"operation":{"initiatedBy":{"username":"terraform"},"sync":{"prune":true,"syncStrategy":{"hook":{}}}}}'

# Wait for sync to complete
echo "⏳ Waiting for VSO sync to complete..."
timeout 600s sh -c 'while true; do
  sync_status=$(kubectl get app -n argocd vault-secrets-operator -o jsonpath="{.status.sync.status}" 2>/dev/null || echo "Unknown")
  health_status=$(kubectl get app -n argocd vault-secrets-operator -o jsonpath="{.status.health.status}" 2>/dev/null || echo "Unknown")
  
  if [ "$sync_status" = "Synced" ]; then
    echo "✅ VSO synced (Health: $health_status)"
    exit 0
  fi
  echo "Sync status: $sync_status, Health: $health_status"
  sleep 5
done'

if [ $? -ne 0 ]; then
  echo "❌ Timeout waiting for VSO sync"
  exit 1
fi

# Wait for VSO CRDs to be available
echo "⏳ Waiting for VSO CRDs..."
crds="vaultauths.secrets.hashicorp.com vaultstaticsecrets.secrets.hashicorp.com vaultdynamicsecrets.secrets.hashicorp.com vaultpkisecrets.secrets.hashicorp.com"
for crd in $crds; do
  timeout 120s sh -c "until kubectl get crd $crd >/dev/null 2>&1; do
    sleep 2
  done"
  
  if [ $? -eq 0 ]; then
    echo "✅ CRD $crd is ready"
  else
    echo "⚠️  Warning: CRD $crd not found after timeout"
  fi
done

# Wait for VSO deployment to be ready
echo "⏳ Waiting for VSO deployment..."
kubectl wait --for=condition=available --timeout=300s deployment -n vault-secrets-operator-system vault-secrets-operator-controller-manager || true

# Wait for VSO webhook to be ready
kubectl wait --for=condition=ready --timeout=300s pod -n vault-secrets-operator-system -l control-plane=controller-manager || true

echo "✅ VSO synced successfully"