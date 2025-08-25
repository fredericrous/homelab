#!/bin/bash
set -euo pipefail

echo "🧪 Running Velero smoke test..."

# Wait for Velero deployment
echo "⏳ Waiting for Velero deployment..."
kubectl wait --for=condition=available --timeout=300s deployment/velero -n velero

# Check Velero pod status
echo "🔍 Checking Velero pod status..."
kubectl get pods -n velero

# Get Velero pod name
VELERO_POD=$(kubectl get pod -n velero -l app.kubernetes.io/name=velero -o name | head -1)

# Verify backup location
echo "🔍 Verifying backup storage location..."
kubectl exec -n velero $VELERO_POD -- /velero backup-location get

# Create a test backup
TEST_NS="${TEST_NS:-default}"
BACKUP_NAME="test-backup-$(date +%s)"

echo "📦 Creating test backup of namespace: $TEST_NS"
kubectl exec -n velero $VELERO_POD -- /velero backup create $BACKUP_NAME \
    --include-namespaces $TEST_NS \
    --wait

# Check backup status
echo "🔍 Checking backup status..."
kubectl exec -n velero $VELERO_POD -- /velero backup describe $BACKUP_NAME

# List all backups
echo "📋 Listing all backups..."
kubectl exec -n velero $VELERO_POD -- /velero backup get

# Check schedules
echo "📅 Checking backup schedules..."
kubectl exec -n velero $VELERO_POD -- /velero schedule get

# Cleanup test backup
echo "🧹 Cleaning up test backup..."
kubectl exec -n velero $VELERO_POD -- /velero backup delete $BACKUP_NAME --confirm

echo "✅ Velero smoke test completed successfully!"