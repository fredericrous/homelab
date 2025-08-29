#!/bin/bash
set -e

# MinIO configuration
MINIO_ALIAS="qnap"
MINIO_URL="http://192.168.1.42:9000"
MINIO_USER="admin"
MINIO_PASS="${MINIO_ROOT_PASSWORD:-changeme123}"

# Get AWS credentials from QNAP Vault
export VAULT_ADDR=http://192.168.1.42:8200
if [ -z "$VAULT_TOKEN" ]; then
    echo "❌ VAULT_TOKEN not set. Please export VAULT_TOKEN with access to secret/velero"
    exit 1
fi

echo "🔑 Fetching AWS credentials from Vault..."
AWS_CREDS=$(vault kv get -format=json secret/velero | jq -r '.data.data')
S3_ACCESS_KEY=$(echo "$AWS_CREDS" | jq -r '.aws_access_key_id')
S3_SECRET_KEY=$(echo "$AWS_CREDS" | jq -r '.aws_secret_access_key')

# S3 configuration
S3_ALIAS="aws"
S3_ENDPOINT="https://s3.eu-west-1.amazonaws.com"
S3_REGION="eu-west-1"
S3_BUCKET="homelab-backups"

echo "🔧 Configuring MinIO client..."
mc alias set $MINIO_ALIAS $MINIO_URL $MINIO_USER $MINIO_PASS

echo "📦 Creating backup bucket..."
mc mb $MINIO_ALIAS/velero-backups --ignore-existing

echo "🔄 Verifying S3 credentials..."
mc alias set $S3_ALIAS $S3_ENDPOINT $S3_ACCESS_KEY $S3_SECRET_KEY --api S3v4

echo "📁 Creating required directories..."
mkdir -p /VMs/minio/scripts /VMs/minio/logs

echo "🗓️ Setting up lifecycle policy..."
./setup-lifecycle.sh

echo "✅ QNAP MinIO configured with 60-day retention!"

echo ""
echo "📊 Setup complete! Next steps:"
echo ""
echo "1. Store AWS credentials in QNAP Vault:"
echo "   vault kv put secret/velero \\"
echo "     aws_access_key_id='YOUR_KEY' \\"
echo "     aws_secret_access_key='YOUR_SECRET'"
echo ""
echo "2. Create secret for Kubernetes MinIO to sync to QNAP:"
echo "   kubectl create secret generic qnap-minio-credentials \\"
echo "     --namespace=velero \\"
echo "     --from-literal=password='$MINIO_PASS'"
echo ""
echo "3. Configure Velero to use Kubernetes MinIO (not QNAP):"
echo "   - URL: http://minio.velero.svc.cluster.local:9000"
echo "   - Access Key: minio"
echo "   - Secret Key: minio123  # Change this!"