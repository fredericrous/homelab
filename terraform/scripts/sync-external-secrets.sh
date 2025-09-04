#!/bin/bash
# sync-external-secrets.sh - Deploy and sync External Secrets Operator
#
# This script ensures ESO is deployed via ArgoCD.
# ESO has much better ArgoCD integration than VSO.
#
set -e

# Parameters
KUBECONFIG="${1:?Error: KUBECONFIG path required as first argument}"
export KUBECONFIG

echo "🔐 Waiting for External Secrets Operator application to be created by ApplicationSet..."
timeout 150s bash -c 'until kubectl get app -n argocd external-secrets-operator >/dev/null 2>&1; do
  echo "Waiting for ESO application..."
  sleep 5
done'

if [ $? -eq 0 ]; then
  echo "✅ ESO application found"
else
  echo "❌ Timeout waiting for ESO application"
  exit 1
fi

echo "🔐 Syncing External Secrets Operator..."
# Create namespace if it doesn't exist
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -

# Force sync ESO app
echo "🔄 Initiating ESO sync..."
kubectl patch app -n argocd external-secrets-operator --type merge -p '{"operation":{"initiatedBy":{"username":"terraform"},"sync":{"prune":true}}}'

# Wait for sync to complete
echo "⏳ Waiting for ESO sync to complete..."
timeout 300s bash -c 'while true; do
  sync_status=$(kubectl get app -n argocd external-secrets-operator -o jsonpath="{.status.sync.status}" 2>/dev/null || echo "Unknown")
  health_status=$(kubectl get app -n argocd external-secrets-operator -o jsonpath="{.status.health.status}" 2>/dev/null || echo "Unknown")
  
  if [ "$sync_status" = "Synced" ]; then
    echo "✅ ESO synced (Health: $health_status)"
    exit 0
  fi
  
  # Check if deployment exists
  if kubectl get deployment -n external-secrets external-secrets-operator >/dev/null 2>&1; then
    echo "✅ ESO deployment exists (Sync: $sync_status, Health: $health_status)"
    exit 0
  fi
  
  echo "Sync status: $sync_status, Health: $health_status"
  sleep 5
done'

if [ $? -ne 0 ]; then
  echo "❌ Timeout waiting for ESO sync"
  exit 1
fi

# Wait for ESO webhook to be ready
echo "⏳ Waiting for ESO webhook..."
kubectl wait --for=condition=ready --timeout=120s pod -n external-secrets -l app.kubernetes.io/name=external-secrets-webhook || true

# Wait for ESO cert controller to be ready
echo "⏳ Waiting for ESO cert controller..."
kubectl wait --for=condition=ready --timeout=120s pod -n external-secrets -l app.kubernetes.io/name=external-secrets-cert-controller || true

# Wait for main controller
echo "⏳ Waiting for ESO controller..."
kubectl wait --for=condition=ready --timeout=120s pod -n external-secrets -l app.kubernetes.io/name=external-secrets || true

# Check CRDs
echo "🔍 Checking ESO CRDs..."
crds="externalsecrets.external-secrets.io secretstores.external-secrets.io clustersecretstores.external-secrets.io"
for crd in $crds; do
  if kubectl get crd $crd >/dev/null 2>&1; then
    echo "✅ CRD $crd is ready"
  else
    echo "❌ CRD $crd not found"
    exit 1
  fi
done

echo "✅ External Secrets Operator synced successfully!"