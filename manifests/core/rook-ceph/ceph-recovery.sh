#!/bin/bash
# Comprehensive Ceph recovery script for post-reboot issues

set -e

echo "=== Ceph Cluster Recovery Script ==="
echo "This script helps recover Ceph after VM reboots"
echo ""

# Function to wait for condition
wait_for() {
    local condition=$1
    local timeout=${2:-60}
    echo "Waiting for: $condition (timeout: ${timeout}s)"
    kubectl wait --for=condition=$condition --timeout=${timeout}s "$@" || true
}

# Step 1: Check node status
echo "Step 1: Checking Kubernetes nodes..."
kubectl get nodes
echo ""

# Step 2: Fix any network issues
echo "Step 2: Restarting network components..."
echo "Restarting Cilium..."
kubectl rollout restart ds -n kube-system cilium
sleep 30

# Step 3: Clean up stale pods
echo "Step 3: Cleaning up stale Ceph pods..."
kubectl delete pods -n rook-ceph --field-selector=status.phase=Succeeded 2>/dev/null || true
kubectl delete pods -n rook-ceph --field-selector=status.phase=Failed 2>/dev/null || true

# Step 4: Ensure monitors are properly scaled
echo "Step 4: Ensuring proper monitor count..."
kubectl patch cephcluster -n rook-ceph rook-ceph --type=merge -p '{"spec":{"mon":{"count":3}}}'

# Step 5: Ensure MGR count is 2
echo "Step 5: Ensuring proper MGR count..."
kubectl patch cephcluster -n rook-ceph rook-ceph --type=merge -p '{"spec":{"mgr":{"count":2}}}'

# Step 6: Restart the operator
echo "Step 6: Restarting Rook operator..."
kubectl delete pod -n rook-ceph -l app=rook-ceph-operator
sleep 30

# Step 7: Check monitor status
echo "Step 7: Checking monitor status..."
kubectl get pods -n rook-ceph -l app=rook-ceph-mon

# Step 8: Force delete stuck volume attachments
echo "Step 8: Cleaning up stuck volume attachments..."
for va in $(kubectl get volumeattachments -o name | grep rook-ceph); do
  # Check if the node exists
  node=$(kubectl get $va -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
  if [ -n "$node" ]; then
    kubectl get node $node &>/dev/null || {
      echo "Deleting stuck volume attachment: $va (node $node doesn't exist)"
      kubectl delete $va --force --grace-period=0
    }
  fi
done

# Step 9: Restart CSI components
echo "Step 9: Restarting CSI components..."
kubectl rollout restart deployment -n rook-ceph -l app=csi-rbdplugin-provisioner
kubectl rollout restart deployment -n rook-ceph -l app=csi-cephfsplugin-provisioner
kubectl rollout restart daemonset -n rook-ceph csi-rbdplugin
kubectl rollout restart daemonset -n rook-ceph csi-cephfsplugin

# Step 10: Wait for monitors to be ready
echo "Step 10: Waiting for monitors to be ready..."
for i in {1..5}; do
  echo "Attempt $i/5..."
  kubectl wait --for=condition=ready pod -n rook-ceph -l app=rook-ceph-mon --timeout=60s && break
  sleep 10
done

# Step 11: Create recovery configmap if needed
echo "Step 11: Creating recovery helpers..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: rook-ceph-recovery-helper
  namespace: rook-ceph
data:
  recovery.sh: |
    #!/bin/bash
    # Helper script to run inside containers
    echo "Monitor endpoints:"
    cat /etc/ceph/ceph.conf | grep "mon host"
    echo ""
    echo "Trying direct monitor connection..."
    timeout 5 ceph -s || echo "Direct connection failed"
EOF

echo ""
echo "=== Recovery Summary ==="
echo "1. Network components restarted"
echo "2. Stale pods cleaned up"
echo "3. Monitor and MGR counts verified (3 monitors, 2 MGRs)"
echo "4. Operator restarted"
echo "5. Volume attachments cleaned"
echo "6. CSI components restarted"
echo ""
echo "Monitor the recovery with:"
echo "  watch kubectl get pods -n rook-ceph"
echo ""
echo "Check Ceph status with:"
echo "  kubectl exec -n rook-ceph <mon-pod> -- ceph -s"
echo ""
echo "If monitors still can't communicate, check:"
echo "1. DNS resolution: kubectl exec -n rook-ceph <pod> -- nslookup ceph-mon.rook-ceph.svc.cluster.local"
echo "2. Network connectivity: kubectl exec -n rook-ceph <pod> -- ping <monitor-ip>"
echo "3. Firewall/iptables rules on nodes"