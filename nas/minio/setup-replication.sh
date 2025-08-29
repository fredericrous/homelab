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

echo "🔄 Setting up S3 alias for weekly sync..."
mc alias set $S3_ALIAS $S3_ENDPOINT $S3_ACCESS_KEY $S3_SECRET_KEY --api S3v4

echo "📝 Creating weekly S3 sync script..."
cat > /VMs/minio/sync-to-s3.sh <<'EOF'
#!/bin/bash
set -e

# Source Vault credentials
export VAULT_ADDR=http://192.168.1.42:8200
export VAULT_TOKEN=$(cat /VMs/vault/root-token)

# Get fresh AWS credentials
AWS_CREDS=$(vault kv get -format=json secret/velero | jq -r '.data.data')
export AWS_ACCESS_KEY_ID=$(echo "$AWS_CREDS" | jq -r '.aws_access_key_id')
export AWS_SECRET_ACCESS_KEY=$(echo "$AWS_CREDS" | jq -r '.aws_secret_access_key')

# Configure mc
mc alias set qnap http://localhost:9000 admin ${MINIO_ROOT_PASSWORD}
mc alias set aws https://s3.eu-west-1.amazonaws.com $AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY

# Sync to S3
echo "$(date): Starting sync to S3..."
mc mirror --overwrite --remove qnap/velero-backups aws/homelab-backups
echo "$(date): Sync complete!"
EOF

chmod +x /VMs/minio/sync-to-s3.sh

echo "📅 Setting up weekly cron job..."
echo "0 3 * * 0 /VMs/minio/sync-to-s3.sh >> /VMs/minio/sync.log 2>&1" | crontab -

echo "✅ Weekly S3 sync configured (Sundays at 3 AM)"

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