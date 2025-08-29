#!/bin/bash
set -e

# Docker host configuration
export DOCKER_HOST=192.168.1.42:2376
export DOCKER_TLS_VERIFY=1
export DOCKER_CERT_PATH="$(pwd)/cert"

echo "🚀 Deploying services to Docker Swarm on QNAP..."

# Deploy Vault
echo "📦 Deploying Vault..."
docker stack deploy -c vault/docker-compose.yml vault

# Deploy MinIO
echo "📦 Deploying MinIO..."
docker stack deploy -c minio/docker-compose.yml minio

echo "✅ Deployment complete!"
echo ""
echo "Services will be available at:"
echo "  - Vault: http://192.168.1.42:8200"
echo "  - MinIO: http://192.168.1.42:9000"
echo "  - MinIO Console: http://192.168.1.42:9001"
echo ""
echo "📅 Deploying S3 sync cron job..."
docker stack deploy -c minio/docker-compose-cron.yml minio-cron

echo ""
echo "Check status with:"
echo "  docker service ls"