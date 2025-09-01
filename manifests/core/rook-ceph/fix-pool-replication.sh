#!/bin/bash
# Script to adjust Ceph pool replication for 2-node cluster

export KUBECONFIG="${1:-$KUBECONFIG}"

echo "🔧 Adjusting Ceph pool replication settings..."

# Get mgr pod
MGR_POD=$(kubectl get pod -n rook-ceph -l app=rook-ceph-mgr -o jsonpath='{.items[0].metadata.name}')

if [ -z "$MGR_POD" ]; then
    echo "❌ No mgr pod found"
    exit 1
fi

echo "Using mgr pod: $MGR_POD"

# Function to set pool size
set_pool_size() {
    local pool=$1
    echo "Adjusting pool: $pool"
    kubectl exec -n rook-ceph $MGR_POD -- ceph osd pool set $pool size 2
    kubectl exec -n rook-ceph $MGR_POD -- ceph osd pool set $pool min_size 1
    echo "✅ Pool $pool adjusted to size=2, min_size=1"
}

# Get all pools
echo "Getting pool list..."
POOLS=$(kubectl exec -n rook-ceph $MGR_POD -- ceph osd pool ls 2>/dev/null)

if [ -z "$POOLS" ]; then
    echo "❌ Could not get pool list"
    exit 1
fi

# Adjust each pool
while IFS= read -r pool; do
    if [ ! -z "$pool" ]; then
        set_pool_size "$pool"
    fi
done <<< "$POOLS"

# Set cluster config to default to 2 replicas
echo "Setting cluster defaults..."
kubectl exec -n rook-ceph $MGR_POD -- ceph config set global osd_pool_default_size 2
kubectl exec -n rook-ceph $MGR_POD -- ceph config set global osd_pool_default_min_size 1
kubectl exec -n rook-ceph $MGR_POD -- ceph config set mon mon_warn_on_pool_no_redundancy false

echo "✅ Cluster defaults set"

# Check health
echo ""
echo "Checking cluster health..."
kubectl exec -n rook-ceph $MGR_POD -- ceph health

echo ""
echo "✅ Pool replication adjustment complete"