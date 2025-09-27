#!/bin/bash
# Bootstrap MinIO credentials in Vault

set -euo pipefail

# Wait for Vault to be ready
echo "Waiting for Vault to be ready..."
for i in {1..60}; do
    if kubectl get pod -n vault -l app.kubernetes.io/name=vault &>/dev/null && kubectl get secret vault-admin-token -n vault &>/dev/null; then
        echo "✅ Vault is ready"
        break
    fi
    echo "Waiting for Vault... ($i/60)"
    sleep 5
done

# Set up port forward
echo "Setting up Vault port forward..."
kubectl port-forward -n vault svc/vault 8200:8200 &>/dev/null &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT

# Wait for port forward
sleep 3

# Set Vault environment
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$(kubectl get secret vault-admin-token -n vault -o jsonpath='{.data.token}' | base64 -d)

echo "Creating MinIO credentials in Vault..."

# Check if secret already exists
if vault kv get secret/minio &>/dev/null; then
    echo "MinIO credentials already exist in Vault, skipping..."
    exit 0
fi

# Generate secure credentials
MINIO_ROOT_USER="minioadmin"
MINIO_ROOT_PASSWORD=$(openssl rand -base64 32)

# Store in Vault
echo "Storing MinIO credentials in Vault..."
vault kv put secret/minio \
    root-user="$MINIO_ROOT_USER" \
    root-password="$MINIO_ROOT_PASSWORD"

echo "MinIO credentials successfully created in Vault"
echo "Root user: $MINIO_ROOT_USER"