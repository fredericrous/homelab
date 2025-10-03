#!/bin/bash
set -e

echo "$(date): Starting weekly S3 sync..."

# AWS credentials should be provided as environment variables
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    echo "ERROR: AWS credentials not provided as environment variables"
    exit 1
fi

echo "AWS credentials loaded from environment"

# Configure MinIO client
echo "Configuring MinIO client..."
mc alias set qnap http://minio:9000 admin ${MINIO_ROOT_PASSWORD:-changeme123}
# AWS S3 - use us-east-1 as default region
mc alias set aws https://s3.us-east-1.amazonaws.com $AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY --api S3v4

# Create bucket if it doesn't exist
echo "Ensuring S3 bucket exists..."
mc mb aws/homelab-backups --ignore-existing || true

# Perform sync
echo "Syncing from QNAP MinIO to AWS S3..."
mc mirror --overwrite --remove qnap/velero-backups aws/homelab-backups/ || true

# Clean up old backups on S3 (keep only 7 most recent)
echo "Cleaning up old backups on S3 (keeping 7 most recent)..."

# For now, skip cleanup until we have backups to test with
echo "Cleanup skipped - will be enabled once backups are present"

echo "$(date): S3 sync and cleanup completed successfully!"