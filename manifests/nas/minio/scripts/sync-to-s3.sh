#!/bin/sh
set -e

echo "$(date): Starting weekly S3 sync..."

# Vault should be configured via environment variables
if [ -z "$VAULT_TOKEN" ]; then
    echo "ERROR: VAULT_TOKEN not set"
    exit 1
fi

if [ -z "$VAULT_ADDR" ]; then
    echo "ERROR: VAULT_ADDR not set"
    exit 1
fi

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

# Clean up old backups on S3 (keep only 7 most recent)
echo "Cleaning up old backups on S3 (keeping 7 most recent)..."

# Get all backup folders sorted by date (newest first)
BACKUPS=$(mc ls aws/homelab-backups/backups/ | grep PRE | awk '{print $5}' | sort -r)

# Count total backups
TOTAL_BACKUPS=$(echo "$BACKUPS" | wc -l)

if [ $TOTAL_BACKUPS -gt 7 ]; then
    echo "Found $TOTAL_BACKUPS backups, removing $(($TOTAL_BACKUPS - 7)) oldest..."
    
    # Get backups to delete (all except the 7 newest)
    TO_DELETE=$(echo "$BACKUPS" | tail -n +8)
    
    # Delete old backups
    for backup in $TO_DELETE; do
        echo "Deleting old backup: $backup"
        mc rm -r --force "aws/homelab-backups/backups/$backup"
    done
    
    echo "Cleanup complete. Kept 7 most recent backups."
else
    echo "Found $TOTAL_BACKUPS backups. No cleanup needed (limit is 7)."
fi

echo "$(date): S3 sync and cleanup completed successfully!"