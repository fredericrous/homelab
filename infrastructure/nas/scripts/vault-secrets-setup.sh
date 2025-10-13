#!/bin/bash
# Setup Vault secrets for MinIO and AWS

set -euo pipefail

echo "🔐 Setting up Vault secrets for QNAP services..."

# Enable KV v2 if not already enabled
if ! vault secrets list | grep -q "^secret/"; then
  echo "📦 Enabling KV v2 secrets engine..."
  vault secrets enable -path=secret kv-v2
fi

# Setup MinIO password
if vault kv get secret/minio &>/dev/null 2>&1; then
  echo "✅ MinIO credentials already exist in Vault"
  EXISTING_PASSWORD=$(vault kv get -field=root_password secret/minio 2>/dev/null || true)
  if [ -n "$EXISTING_PASSWORD" ]; then
    echo "   Using existing password from Vault"
    MINIO_ROOT_PASSWORD="$EXISTING_PASSWORD"
  else
    echo "⚠️  Password field empty, generating new one..."
    MINIO_ROOT_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
  fi
else
  echo "🎲 Generating secure password for MinIO..."
  MINIO_ROOT_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
fi

echo "💾 Storing MinIO credentials in Vault..."
vault kv put secret/minio \
  root_user=admin \
  root_password="$MINIO_ROOT_PASSWORD"

echo "✅ MinIO credentials stored in Vault at secret/minio"

# Check if MinIO is deployed and update secret
if kubectl get deployment minio -n minio &>/dev/null 2>&1; then
  echo ""
  echo "⚠️  MinIO is already deployed. Updating Kubernetes secret..."
  MINIO_ROOT_PASSWORD=$(vault kv get -field=root_password secret/minio)
  kubectl -n minio create secret generic minio-root-user \
    --from-literal=rootUser=admin \
    --from-literal=rootPassword="$MINIO_ROOT_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "✅ MinIO secret updated. Restart MinIO to apply:"
  echo "   kubectl -n minio rollout restart deployment minio"
fi

# Setup AWS credentials
echo ""
echo "☁️  Setting up AWS credentials for S3 sync..."

# Check if already exists
if vault kv get secret/velero &>/dev/null 2>&1; then
  echo "✅ AWS credentials already exist in Vault"
  echo -n "   Update them? (y/N): "
  read -r UPDATE_AWS < /dev/tty
  if [[ "$UPDATE_AWS" =~ ^[Yy]$ ]]; then
    AWS_SETUP_NEEDED=true
  fi
else
  AWS_SETUP_NEEDED=true
fi

if [ "${AWS_SETUP_NEEDED:-false}" = "true" ]; then
  # Check environment variables first
  if [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
    echo "📦 Found AWS credentials in environment variables"
    vault kv put secret/velero \
      aws_access_key_id="$AWS_ACCESS_KEY_ID" \
      aws_secret_access_key="$AWS_SECRET_ACCESS_KEY"
    echo "✅ AWS credentials stored in Vault"
  else
    echo "🔑 Enter AWS credentials for S3 backup sync:"
    echo -n "   AWS Access Key ID: "
    read -r AWS_ACCESS_KEY_ID < /dev/tty
    echo -n "   AWS Secret Access Key: "
    read -rs AWS_SECRET_ACCESS_KEY < /dev/tty
    echo ""

    if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ]; then
      vault kv put secret/velero \
        aws_access_key_id="$AWS_ACCESS_KEY_ID" \
        aws_secret_access_key="$AWS_SECRET_ACCESS_KEY"
      echo "✅ AWS credentials stored in Vault at secret/velero"
    else
      echo "⚠️  Skipping AWS credentials setup (S3 sync will not work)"
    fi
  fi
fi

# Create Kubernetes secret if MinIO is deployed
if kubectl get deployment minio -n minio &>/dev/null 2>&1; then
  if vault kv get secret/velero &>/dev/null 2>&1; then
    echo ""
    echo "📦 Updating AWS credentials secret..."
    AWS_KEY=$(vault kv get -field=aws_access_key_id secret/velero)
    AWS_SECRET=$(vault kv get -field=aws_secret_access_key secret/velero)

    kubectl -n minio create secret generic aws-credentials \
      --from-literal=aws_access_key_id="$AWS_KEY" \
      --from-literal=aws_secret_access_key="$AWS_SECRET" \
      --dry-run=client -o yaml | kubectl apply -f -
    echo "✅ AWS credentials secret created/updated"
  fi
fi

echo ""
echo "✅ Vault secrets setup complete!"
echo ""
echo "📋 Summary:"
echo "   MinIO Credentials:"
echo "     Username: admin"
echo "     Password: vault kv get -field=root_password secret/minio"
echo ""
echo "   AWS Credentials:"
echo "     Access Key: vault kv get -field=aws_access_key_id secret/velero"
echo "     Secret Key: vault kv get -field=aws_secret_access_key secret/velero"
echo ""
echo "📌 Next step:"
echo "   Set up transit unseal for main K8s cluster:"
echo "   task nas:vault-transit"