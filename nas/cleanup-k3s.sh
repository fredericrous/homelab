#!/bin/bash
set -e

echo "🧹 Cleaning up K3s cluster on QNAP..."

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export KUBECONFIG="${SCRIPT_DIR}/kubeconfig.yaml"

# Delete all deployed resources
echo "📦 Deleting deployed resources..."

# Delete MinIO
if kubectl get namespace minio &>/dev/null 2>&1; then
    echo "  Deleting MinIO..."
    kubectl delete namespace minio --timeout=60s || true
fi

# Delete Vault
if kubectl get namespace vault &>/dev/null 2>&1; then
    echo "  Deleting Vault..."
    kubectl delete namespace vault --timeout=60s || true
fi

# Delete storage class
if kubectl get storageclass qnap-local &>/dev/null 2>&1; then
    echo "  Deleting storage class..."
    kubectl delete storageclass qnap-local || true
fi

# Clean up any PVs that might be stuck
echo "🗑️  Cleaning up persistent volumes..."
kubectl get pv -o name | xargs -r kubectl delete --timeout=30s || true

# Wait for namespaces to be fully deleted
echo "⏳ Waiting for namespaces to be deleted..."
while kubectl get namespace minio &>/dev/null 2>&1 || kubectl get namespace vault &>/dev/null 2>&1; do
    echo "  Still deleting namespaces..."
    sleep 5
done

echo "✅ K3s cluster cleaned up!"
echo ""
echo "📋 Next steps:"
echo "1. SSH into QNAP to clean up any remaining data:"
echo "   ssh admin@192.168.1.42"
echo "   sudo rm -rf /share/runtime/k3s/storage/*"
echo ""
echo "2. Deploy fresh:"
echo "   ./deploy-k3s-services.sh"
echo ""
echo "⚠️  Note: K3s itself is managed by QNAP and should not be uninstalled"