#!/bin/bash
set -e

# MinIO configuration
MINIO_ALIAS="qnap"
MINIO_URL="http://192.168.1.42:9000"
MINIO_USER="admin"
MINIO_PASS="${MINIO_ROOT_PASSWORD:-changeme123}"

# S3 configuration (same as Vault secret/velero)
S3_ALIAS="aws"
S3_ENDPOINT="https://s3.eu-west-1.amazonaws.com"
S3_REGION="${AWS_DEFAULT_REGION:-eu-west-1}"
S3_ACCESS_KEY="${AWS_ACCESS_KEY_ID}"
S3_SECRET_KEY="${AWS_SECRET_ACCESS_KEY}"
S3_BUCKET="homelab-backups"

echo "🔧 Configuring MinIO client..."
mc alias set $MINIO_ALIAS $MINIO_URL $MINIO_USER $MINIO_PASS

echo "📦 Creating backup bucket..."
mc mb $MINIO_ALIAS/velero-backups --ignore-existing

echo "🔄 Setting up replication to S3..."
if [ -n "$AWS_ACCESS_KEY_ID" ]; then
    mc alias set $S3_ALIAS $S3_ENDPOINT $S3_ACCESS_KEY $S3_SECRET_KEY --api S3v4
    
    # Set up bucket replication
    mc replicate add $MINIO_ALIAS/velero-backups \
        --remote-bucket $S3_ALIAS/$S3_BUCKET \
        --replicate "delete,delete-marker,existing-objects"
    
    echo "✅ Replication to S3 configured!"
else
    echo "⚠️  AWS credentials not set. Skipping S3 replication."
fi

echo ""
echo "📊 MinIO access credentials for Kubernetes Velero:"
echo "  URL: $MINIO_URL"
echo "  Access Key: $MINIO_USER"
echo "  Secret Key: $MINIO_PASS"
echo ""
echo "Create Kubernetes secret with:"
echo "kubectl create secret generic velero-minio-credentials \\"
echo "  --namespace=velero \\"
echo "  --from-literal=cloud=\"[default]\\naws_access_key_id=$MINIO_USER\\naws_secret_access_key=$MINIO_PASS\""