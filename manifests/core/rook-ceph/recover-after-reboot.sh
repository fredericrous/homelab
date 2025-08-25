#!/bin/bash
# Script to recover Ceph cluster after VM reboot

echo "Starting Ceph recovery process..."

# Step 1: Ensure all monitor deployments are scaled up
echo "Scaling up Ceph monitors..."
kubectl scale deployment -n rook-ceph rook-ceph-mon-a --replicas=1
kubectl scale deployment -n rook-ceph rook-ceph-mon-b --replicas=1 2>/dev/null || true
kubectl scale deployment -n rook-ceph rook-ceph-mon-c --replicas=1 2>/dev/null || true

# Step 2: Wait for at least one monitor to be ready
echo "Waiting for monitors to be ready..."
kubectl wait --for=condition=ready pod -n rook-ceph -l ceph_daemon_type=mon --timeout=120s || true

# Step 3: Restart the operator to trigger reconciliation
echo "Restarting Rook operator..."
kubectl delete pod -n rook-ceph -l app=rook-ceph-operator

# Step 4: Wait for operator to be ready
echo "Waiting for operator to be ready..."
sleep 30
kubectl wait --for=condition=ready pod -n rook-ceph -l app=rook-ceph-operator --timeout=120s

# Step 5: Force delete stuck volume attachments if any
echo "Cleaning up stuck volume attachments..."
for va in $(kubectl get volumeattachments -o name | grep rook-ceph); do
  node=$(kubectl get $va -o jsonpath='{.spec.nodeName}')
  if ! kubectl get node $node &>/dev/null; then
    echo "Deleting stuck volume attachment: $va"
    kubectl delete $va --force --grace-period=0
  fi
done

# Step 6: Restart CSI pods to clear any stuck operations
echo "Restarting CSI pods..."
kubectl rollout restart daemonset -n rook-ceph csi-rbdplugin
kubectl rollout restart deployment -n rook-ceph csi-rbdplugin-provisioner

echo "Recovery process initiated. Monitor the cluster with:"
echo "  kubectl get pods -n rook-ceph"
echo "  kubectl logs -n rook-ceph -l app=rook-ceph-operator -f"