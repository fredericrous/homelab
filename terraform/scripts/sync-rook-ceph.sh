#!/bin/bash
set -e

# Parameters
KUBECONFIG="${1:?Error: KUBECONFIG path required as first argument}"
export KUBECONFIG

# Ensure we're using the correct kubeconfig
unset KUBERNETES_MASTER
echo "🔧 Using KUBECONFIG: $KUBECONFIG"

# Test connection
if ! kubectl cluster-info &>/dev/null; then
  echo "❌ Cannot connect to cluster with KUBECONFIG=$KUBECONFIG"
  echo "Testing connection..."
  kubectl cluster-info
  exit 1
fi

# First, check if ArgoCD server is healthy
echo "🔍 Checking ArgoCD server health..."
if ! kubectl wait --for=condition=available --timeout=30s deployment/argocd-server -n argocd >/dev/null 2>&1; then
  echo "⚠️  ArgoCD server is not healthy"
  echo "Run: cd terraform && ./scripts/fix-argocd-env-vars.sh"
  exit 1
fi

echo "💾 Waiting for Rook-Ceph application to be created by ApplicationSet..."
KUBECONFIG_PATH="$KUBECONFIG"
timeout 150s sh -c "export KUBECONFIG='$KUBECONFIG_PATH'; until kubectl get app -n argocd rook-ceph >/dev/null 2>&1; do
  echo \"Waiting for Rook-Ceph application...\"
  sleep 5
done"

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
start_time=$(date +%s)
outofsync_count=0

while true; do
  sync_status=$(kubectl get app -n argocd rook-ceph -o jsonpath="{.status.sync.status}" 2>/dev/null || echo "Unknown")
  health_status=$(kubectl get app -n argocd rook-ceph -o jsonpath="{.status.health.status}" 2>/dev/null || echo "Unknown")
  
  if [ "$sync_status" = "Synced" ]; then
    echo "✅ Rook-Ceph synced (Health: $health_status)"
    break
  fi
  
  # Get more details about the sync status
  operation_phase=$(kubectl get app -n argocd rook-ceph -o jsonpath="{.status.operationState.phase}" 2>/dev/null || echo "")
  
  # If operation is in Error phase, show details and retry
  if [ "$operation_phase" = "Error" ]; then
    echo "❌ Sync operation failed. Getting error details..."
    error_message=$(kubectl get app -n argocd rook-ceph -o jsonpath="{.status.operationState.message}" 2>/dev/null || echo "No error message")
    echo "Error: $error_message"
    
    # Show sync result details
    echo "Sync result:"
    kubectl get app -n argocd rook-ceph -o jsonpath="{.status.operationState.syncResult}" | jq '.' 2>/dev/null || true
    
    # Retry the sync
    echo "🔄 Retrying sync..."
    kubectl patch app -n argocd rook-ceph --type merge -p '{"operation":{"initiatedBy":{"username":"terraform"},"sync":{"prune":true,"retry":{"limit":5}}}}'
    sleep 10
    continue
  fi
  
  # If OutOfSync but Healthy, check if resources are being created
  if [ "$sync_status" = "OutOfSync" ] && [ "$health_status" = "Healthy" ]; then
    # Check if this is the initial sync where resources don't exist yet
    resource_count=$(kubectl get app -n argocd rook-ceph -o jsonpath="{.status.resources}" 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
    synced_count=$(kubectl get app -n argocd rook-ceph -o jsonpath="{.status.resources}" 2>/dev/null | jq '[.[] | select(.status == "Synced")] | length' 2>/dev/null || echo "0")
    
    echo "Sync status: $sync_status, Health: $health_status, Phase: $operation_phase"
    echo "Resources: $synced_count synced out of $resource_count total"
    
    # Check elapsed time
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    
    # If we've been in OutOfSync for a while, check for sync errors
    if [ $elapsed -gt 120 ]; then
      ((outofsync_count++))
      
      # Every 5 checks, show more details
      if [ $((outofsync_count % 5)) -eq 0 ]; then
        echo "Checking for sync issues..."
        kubectl get app -n argocd rook-ceph -o jsonpath="{.status.conditions}" | jq '.' 2>/dev/null || true
        
        # Show any resources that are out of sync
        echo "Out of sync resources:"
        kubectl get app -n argocd rook-ceph -o jsonpath="{.status.resources}" | jq '.[] | select(.status != "Synced") | {name: .name, kind: .kind, status: .status, health: .health}' 2>/dev/null || true
      fi
      
      # If OutOfSync but Healthy for too long, check what's not synced
      if [ $outofsync_count -gt 10 ]; then
        echo "⚠️  Rook-Ceph is OutOfSync but Healthy after multiple checks"
        
        # Check if it's just CRDs waiting for the operator
        unsynced_crds=$(kubectl get app -n argocd rook-ceph -o jsonpath="{.status.resources}" | \
          jq -r '.[] | select(.status != "Synced") | select(.kind | test("^Ceph")) | .kind' 2>/dev/null | sort -u | tr '\n' ' ')
        
        if [ -n "$unsynced_crds" ]; then
          echo "   Unsynced Ceph CRDs: $unsynced_crds"
          echo "   These will sync once the Ceph operator processes them"
        fi
        
        # Check if key resources exist and the operator is ready
        if kubectl get storageclass rook-ceph-block &>/dev/null && \
           kubectl get deployment -n rook-ceph rook-ceph-operator &>/dev/null; then
          echo "✅ Storage class and operator exist - considering sync successful"
          echo "   The Ceph CRs will be reconciled by the operator"
          break
        fi
      fi
    fi
  else
    echo "Sync status: $sync_status, Health: $health_status, Phase: $operation_phase"
  fi
  
  # Check timeout
  current_time=$(date +%s)
  elapsed=$((current_time - start_time))
  if [ $elapsed -gt 600 ]; then
    echo "❌ Timeout waiting for Rook-Ceph sync after 10 minutes"
    exit 1
  fi
  
  sleep 5
done

# Wait for storage class to be available
echo "🔍 Waiting for rook-ceph-block storage class..."
KUBECONFIG_PATH="$KUBECONFIG"
timeout 600s sh -c "export KUBECONFIG='$KUBECONFIG_PATH'; until kubectl get storageclass rook-ceph-block >/dev/null 2>&1; do
  echo \"Waiting for storage class...\"
  sleep 10
done"

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
echo "📊 Monitoring Ceph cluster deployment..."
KUBECONFIG_PATH="$KUBECONFIG"
timeout 300s sh -c "export KUBECONFIG='$KUBECONFIG_PATH'; while true; do
  # Check CephCluster status
  if kubectl get cephcluster -n rook-ceph rook-ceph &>/dev/null; then
    CEPH_PHASE=$(kubectl get cephcluster -n rook-ceph rook-ceph -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    CEPH_MESSAGE=$(kubectl get cephcluster -n rook-ceph rook-ceph -o jsonpath='{.status.message}' 2>/dev/null || echo "")
    CEPH_HEALTH=$(kubectl get cephcluster -n rook-ceph rook-ceph -o jsonpath='{.status.ceph.health}' 2>/dev/null || echo "")
    
    echo "CephCluster: Phase=$CEPH_PHASE, Message=\"$CEPH_MESSAGE\", Health=$CEPH_HEALTH"
  else
    echo "CephCluster resource not found yet..."
  fi
  
  # Check if any Ceph OSD pods are running
  osd_count=\$(kubectl get pods -n rook-ceph -l app=rook-ceph-osd --no-headers 2>/dev/null | grep -c \"Running\" || echo \"0\")
  # Trim any whitespace/newlines
  osd_count=\$(echo \$osd_count | tr -d '[:space:]')
  if [ \"\$osd_count\" -gt \"0\" ]; then
    echo \"✅ Found \$osd_count running OSD pods\"
    break
  fi
  echo \"Waiting for Ceph OSDs to be ready...\"
  sleep 10
done"

# Wait for Ceph health to be OK
echo "🔍 Checking Ceph cluster health..."
KUBECONFIG_PATH="$KUBECONFIG"
timeout 300s sh -c "export KUBECONFIG='$KUBECONFIG_PATH'; while true; do
  # Check Ceph health using the toolbox or operator
  ceph_health=\$(kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph health 2>/dev/null || \\
                kubectl exec -n rook-ceph -l app=rook-ceph-operator -- ceph status -f json-pretty 2>/dev/null | jq -r .health.status 2>/dev/null || \\
                echo \"UNKNOWN\")
  
  if [[ \"\$ceph_health\" == \"HEALTH_OK\" ]] || [[ \"\$ceph_health\" == \"HEALTH_WARN\" ]]; then
    echo \"✅ Ceph cluster health: \$ceph_health\"
    break
  fi
  
  # Alternative: Check if CephCluster CR shows ready
  cluster_ready=\$(kubectl get cephcluster -n rook-ceph rook-ceph -o jsonpath='{.status.phase}' 2>/dev/null || echo \"Unknown\")
  if [[ \"\$cluster_ready\" == \"Ready\" ]]; then
    echo \"✅ CephCluster resource shows Ready\"
    break
  fi
  
  echo \"Ceph health: \$ceph_health, Cluster phase: \$cluster_ready\"
  sleep 5
done"

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
KUBECONFIG_PATH="$KUBECONFIG"
timeout 60s sh -c "export KUBECONFIG='$KUBECONFIG_PATH'; while true; do
  pvc_status=\$(kubectl get pvc test-ceph-pvc -n default -o jsonpath=\"{.status.phase}\" 2>/dev/null || echo \"Unknown\")
  if [ \"\$pvc_status\" = \"Bound\" ]; then
    echo \"✅ Test PVC successfully bound - storage is working\"
    kubectl delete pvc test-ceph-pvc -n default --wait=false
    break
  fi
  echo \"Test PVC status: \$pvc_status\"
  sleep 5
done"

echo "✅ Rook-Ceph storage is ready"