#!/bin/bash
set -e

# Parameters
KUBECONFIG="${1:?Error: KUBECONFIG path required as first argument}"
export KUBECONFIG

echo "💾 Waiting for Rook-Ceph application to be created by ApplicationSet..."
timeout 150s sh -c 'until kubectl get app -n argocd rook-ceph >/dev/null 2>&1; do
  echo "Waiting for Rook-Ceph application..."
  sleep 5
done'

if [ $? -eq 0 ]; then
  echo "✅ Rook-Ceph application found"
else
  echo "❌ Timeout waiting for Rook-Ceph application"
  exit 1
fi

echo "💾 Syncing Rook-Ceph storage operator..."
kubectl patch app -n argocd rook-ceph --type merge -p '{"operation":{"initiatedBy":{"username":"terraform"},"sync":{"prune":true,"syncStrategy":{"hook":{}}}}}'

# Wait for sync to complete
echo "⏳ Waiting for Rook-Ceph sync to complete..."
timeout 600s sh -c 'while true; do
  sync_status=$(kubectl get app -n argocd rook-ceph -o jsonpath="{.status.sync.status}" 2>/dev/null || echo "Unknown")
  health_status=$(kubectl get app -n argocd rook-ceph -o jsonpath="{.status.health.status}" 2>/dev/null || echo "Unknown")
  
  if [ "$sync_status" = "Synced" ]; then
    echo "✅ Rook-Ceph synced (Health: $health_status)"
    exit 0
  fi
  echo "Sync status: $sync_status, Health: $health_status"
  sleep 5
done'

if [ $? -ne 0 ]; then
  echo "❌ Timeout waiting for Rook-Ceph sync"
  exit 1
fi

# Wait for Rook operator to be ready
echo "⏳ Waiting for Rook-Ceph operator pod..."
kubectl wait --for=condition=ready --timeout=300s pod -n rook-ceph -l app=rook-ceph-operator || true

# Wait for storage class to be available
echo "🔍 Waiting for rook-ceph-block storage class..."
timeout 600s sh -c 'until kubectl get storageclass rook-ceph-block >/dev/null 2>&1; do
  echo "Waiting for storage class..."
  sleep 10
done'

if [ $? -eq 0 ]; then
  echo "✅ Storage class rook-ceph-block is available"
  # Also check if the storage class is default
  is_default=$(kubectl get storageclass rook-ceph-block -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}')
  if [ "$is_default" = "true" ]; then
    echo "✅ rook-ceph-block is the default storage class"
  fi
else
  echo "❌ Timeout waiting for storage class"
  exit 1
fi

echo "✅ Rook-Ceph storage is ready"