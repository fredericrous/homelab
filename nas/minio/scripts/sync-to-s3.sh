#!/bin/bash
set -e

echo "$(date): Starting weekly S3 sync..."

# Get Vault token from mounted volume
if [ -f /vault-data/root-token ]; then
    export VAULT_TOKEN=$(cat /vault-data/root-token)
else
    echo "ERROR: Vault root token not found at /vault-data/root-token"
    exit 1
fi

# Configure Vault
export VAULT_ADDR=http://vault:8200
export VAULT_SKIP_VERIFY=true

# Get AWS credentials from Vault
echo "Fetching AWS credentials from Vault..."
AWS_CREDS=$(vault kv get -format=json secret/velero | jq -r '.data.data')
export AWS_ACCESS_KEY_ID=$(echo "$AWS_CREDS" | jq -r '.aws_access_key_id')
export AWS_SECRET_ACCESS_KEY=$(echo "$AWS_CREDS" | jq -r '.aws_secret_access_key')

if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    echo "ERROR: Failed to retrieve AWS credentials from Vault"
    exit 1
fi

# Configure MinIO client
echo "Configuring MinIO client..."
mc alias set qnap http://minio:9000 admin ${MINIO_ROOT_PASSWORD:-changeme123}
mc alias set aws https://s3.eu-west-1.amazonaws.com $AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY

# Perform sync
echo "Syncing from QNAP MinIO to AWS S3..."
mc mirror --overwrite --remove qnap/velero-backups aws/homelab-backups

echo "$(date): S3 sync completed successfully!"