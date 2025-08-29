#!/bin/bash
set -e

# Docker host configuration
export DOCKER_HOST=192.168.1.42:2376
export DOCKER_TLS_VERIFY=1
export DOCKER_CERT_PATH="$(dirname "$0")/../cert"

echo "🕐 Deploying MinIO S3 sync cron job..."

# Ensure scripts directory exists and sync script is in place
echo "📝 Copying sync script to QNAP..."
ssh root@192.168.1.42 "mkdir -p /VMs/minio/scripts /VMs/minio/logs"
scp "$(dirname "$0")/scripts/sync-to-s3.sh" root@192.168.1.42:/VMs/minio/scripts/
ssh root@192.168.1.42 "chmod +x /VMs/minio/scripts/sync-to-s3.sh"

# Deploy the cron stack
docker stack deploy -c docker-compose-cron.yml minio-cron

echo "✅ Cron job deployed!"
echo ""
echo "The S3 sync will run every Sunday at 3 AM"
echo "Only the 7 most recent backups will be kept on S3"
echo ""
echo "To test the sync manually:"
echo "  docker service create --name test-sync \\"
echo "    --mount type=bind,source=/VMs/minio/scripts,target=/scripts,readonly \\"
echo "    --mount type=bind,source=/VMs/vault,target=/vault-data,readonly \\"
echo "    --network minio-net --network vault-net \\"
echo "    minio/mc:RELEASE.2024-08-26T10-49-58Z /scripts/sync-to-s3.sh"