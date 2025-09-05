#!/bin/bash
# Create AWS credentials secret if available

set -euo pipefail

HAS_SECRET=$(kubectl -n minio get secret aws-credentials &>/dev/null && echo "true" || echo "false")
VAULT_READY=$(vault status &>/dev/null 2>&1 && echo "true" || echo "false")

if [ "$HAS_SECRET" = "false" ] && [ "$VAULT_READY" = "true" ]; then
  if vault kv get secret/velero &>/dev/null 2>&1; then
    echo "📦 Creating AWS credentials secret from Vault..."
    AWS_KEY=$(vault kv get -field=aws_access_key_id secret/velero)
    AWS_SECRET=$(vault kv get -field=aws_secret_access_key secret/velero)

    kubectl -n minio create secret generic aws-credentials \
      --from-literal=aws_access_key_id="$AWS_KEY" \
      --from-literal=aws_secret_access_key="$AWS_SECRET"
    echo "✅ AWS credentials secret created from Vault"
  else
    echo "⚠️  AWS credentials not in Vault. Run 'task vault-secrets' to configure"
  fi
fi