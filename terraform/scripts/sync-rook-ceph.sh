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

# Wait for Ceph cluster to be ready to provision volumes
echo "🔍 Checking if Ceph cluster is ready to provision volumes..."

# Wait for OSDs to be running
timeout 300s bash -c 'while true; do
  # Check if any Ceph OSD pods are running
  osd_count=$(kubectl get pods -n rook-ceph -l app=rook-ceph-osd --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  if [ "$osd_count" -gt 0 ]; then
    echo "✅ Found $osd_count running OSD pods"
    break
  fi
  echo "Waiting for Ceph OSDs to be ready..."
  sleep 10
done'

# Wait for Ceph health to be OK
echo "🔍 Checking Ceph cluster health..."
timeout 300s bash -c 'while true; do
  # Check Ceph health using the toolbox or operator
  ceph_health=$(kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph health 2>/dev/null || \
                kubectl exec -n rook-ceph -l app=rook-ceph-operator -- ceph status -f json-pretty 2>/dev/null | jq -r .health.status 2>/dev/null || \
                echo "UNKNOWN")
  
  if [[ "$ceph_health" == "HEALTH_OK" ]] || [[ "$ceph_health" == "HEALTH_WARN" ]]; then
    echo "✅ Ceph cluster health: $ceph_health"
    break
  fi
  
  # Alternative: Check if CephCluster CR shows ready
  cluster_ready=$(kubectl get cephcluster -n rook-ceph rook-ceph -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  if [[ "$cluster_ready" == "Ready" ]]; then
    echo "✅ CephCluster resource shows Ready"
    break
  fi
  
  echo "Ceph health: $ceph_health, Cluster phase: $cluster_ready"
  sleep 5
done'

# Test that we can actually create a PVC
echo "🧪 Testing PVC creation..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-ceph-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: rook-ceph-block
  resources:
    requests:
      storage: 1Gi
EOF

# Wait for test PVC to be bound
timeout 60s bash -c 'while true; do
  pvc_status=$(kubectl get pvc test-ceph-pvc -n default -o jsonpath="{.status.phase}" 2>/dev/null || echo "Unknown")
  if [ "$pvc_status" = "Bound" ]; then
    echo "✅ Test PVC successfully bound - storage is working"
    kubectl delete pvc test-ceph-pvc -n default --wait=false
    break
  fi
  echo "Test PVC status: $pvc_status"
  sleep 5
done'

echo "✅ Rook-Ceph storage is ready"