#!/bin/bash
set -euo pipefail

echo "🔍 Detecting namespaces with PVCs..."

# Get all namespaces with PVCs
NAMESPACES_WITH_PVCS=$(kubectl get pvc --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u | grep -v '^$' || true)

# Get storage classes and their provisioners
echo "🔍 Detecting storage classes and CSI drivers..."
STORAGE_CLASSES=$(kubectl get storageclass -o json)

# Detect CSI drivers
CSI_DRIVERS=""
if echo "$STORAGE_CLASSES" | grep -q "rook-ceph.rbd.csi.ceph.com"; then
    CSI_DRIVERS="${CSI_DRIVERS}rbd "
fi
if echo "$STORAGE_CLASSES" | grep -q "rook-ceph.cephfs.csi.ceph.com"; then
    CSI_DRIVERS="${CSI_DRIVERS}cephfs "
fi
if echo "$STORAGE_CLASSES" | grep -q "smb.csi.k8s.io"; then
    CSI_DRIVERS="${CSI_DRIVERS}smb "
fi

echo "📦 Found CSI drivers: ${CSI_DRIVERS:-none}"

# Generate backup schedules for both locations
BACKUP_SCHEDULES=""
for ns in $NAMESPACES_WITH_PVCS; do
    # Skip system namespaces
    if [[ "$ns" =~ ^(kube-|rook-|metallb-|cert-manager|vault-secrets-operator|linkerd|cilium|node-feature-discovery).*$ ]]; then
        echo "⏭️  Skipping system namespace: $ns"
        continue
    fi
    
    echo "✅ Adding backup schedules for namespace: $ns"
    
    # Add SMB backup schedule (every 2 days)
    SCHEDULE_NAME="${ns}-smb-backup"
    if [ -n "$BACKUP_SCHEDULES" ]; then
        BACKUP_SCHEDULES="${BACKUP_SCHEDULES}
  "
    fi
    BACKUP_SCHEDULES="${BACKUP_SCHEDULES}${SCHEDULE_NAME}:
    schedule: \"0 2 */2 * *\"  # Every 2 days at 2 AM
    template:
      ttl: 87600h  # 10 years (effectively forever)
      includedNamespaces:
        - ${ns}
      # Using file system backup via restic
      volumeSnapshotLocations:
        - rook-ceph
  
  # AWS Glacier backup schedule (every 25 days)
  ${ns}-aws-backup:
    schedule: \"0 3 */25 * *\"  # Every 25 days at 3 AM
    template:
      ttl: 87600h  # 10 years (effectively forever)
      includedNamespaces:
        - ${ns}
      storageLocation: default
      volumeSnapshotLocations:
        - rook-ceph"
done

# Update environment variables
export BUCKET_NAME="${BUCKET_NAME:-homelab-backups}"
export REGION="${REGION:-eu-west-1}"
export S3_URL="${S3_URL:-https://s3.eu-west-1.amazonaws.com}"

echo "📝 Generating values file with schedules..."

# Read the template
TEMPLATE=$(cat /Users/fredericrous/Developer/Perso/homelab/manifests/backup/base/values-velero-updated.yaml)

# Replace placeholders
FINAL_VALUES=$(echo "$TEMPLATE" | sed "s|\${BUCKET_NAME}|${BUCKET_NAME}|g")
FINAL_VALUES=$(echo "$FINAL_VALUES" | sed "s|\${REGION}|${REGION}|g")
FINAL_VALUES=$(echo "$FINAL_VALUES" | sed "s|\${S3_URL}|${S3_URL}|g")

# Handle multiline schedule replacement
if [ -n "$BACKUP_SCHEDULES" ]; then
    # Write schedules to a temporary file
    TMP_SCHEDULES=$(mktemp)
    echo "$BACKUP_SCHEDULES" > "$TMP_SCHEDULES"
    
    # Use perl for multiline replacement
    FINAL_VALUES=$(echo "$FINAL_VALUES" | perl -pe "BEGIN{open(F,'$TMP_SCHEDULES'); \$schedules=join('',<F>); close(F)} s/\\\$\{BACKUP_SCHEDULES\}/\$schedules/")
    
    rm "$TMP_SCHEDULES"
else
    # No schedules, remove the placeholder
    FINAL_VALUES=$(echo "$FINAL_VALUES" | sed '/\${BACKUP_SCHEDULES}/d')
fi

# Write the updated values
echo "$FINAL_VALUES" > /Users/fredericrous/Developer/Perso/homelab/manifests/backup/base/values-velero.yaml

echo "✅ Velero configuration prepared successfully!"
echo ""
echo "📋 Summary:"
echo "  - Namespaces to backup: $(echo "$NAMESPACES_WITH_PVCS" | grep -v '^kube-\|^rook-\|^metallb-\|^cert-manager\|^vault-secrets-operator\|^linkerd\|^cilium\|^node-feature-discovery' | wc -l | tr -d ' ')"
echo "  - CSI drivers detected: ${CSI_DRIVERS:-none}"
echo "  - AWS S3 endpoint: ${S3_URL}"
echo "  - Bucket: ${BUCKET_NAME}"
echo "  - SMB backup via MinIO: http://minio-smb.velero.svc.cluster.local:9000"
echo ""
echo "⚠️  Note: Make sure to:"
echo "  1. Configure AWS credentials in Vault at secret/velero"
echo "  2. Configure MinIO password in Vault at secret/velero/minio"
echo "  3. Create the S3 bucket '${BUCKET_NAME}' in AWS"
echo "  4. Deploy MinIO for SMB backups"