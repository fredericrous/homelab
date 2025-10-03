#!/bin/bash
# Ensure MinIO root user secret exists

set -euo pipefail

HAS_SECRET=$(kubectl -n minio get secret minio-root-user &>/dev/null && echo "true" || echo "false")

if [ "$HAS_SECRET" = "false" ]; then
  echo "🔐 Creating MinIO root user secret..."

  # Try to get password from Vault
  if vault status &>/dev/null 2>&1 && vault kv get secret/minio &>/dev/null 2>&1; then
    echo "  Using password from Vault"
    MINIO_ROOT_PASSWORD=$(vault kv get -field=root_password secret/minio)
  else
    echo "  ⚠️  Vault not available, using default password"
    echo "     Run 'task nas:vault-secrets' after Vault is ready to secure it"
    MINIO_ROOT_PASSWORD="changeme123"
  fi

  kubectl -n minio create secret generic minio-root-user \
    --from-literal=rootUser=admin \
    --from-literal=rootPassword="$MINIO_ROOT_PASSWORD"
else
  echo "✅ MinIO root user secret already exists"
fi