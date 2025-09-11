#!/bin/bash
# Setup local configuration from templates
# This script helps users configure their local environment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🔧 Setting up local configuration..."

# Check if .env exists
if [ ! -f "$ROOT_DIR/.env" ]; then
    echo "📝 Creating .env from .env.example..."
    cp "$ROOT_DIR/.env.example" "$ROOT_DIR/.env"
    echo "⚠️  Please edit .env with your values"
fi

# Load environment variables
if [ -f "$ROOT_DIR/.env" ]; then
    set -a
    source "$ROOT_DIR/.env"
    set +a
fi

# Create local configs from examples
echo "📄 Creating local configuration files..."

# Vault QNAP config
if [ ! -f "$ROOT_DIR/manifests/core/vault/qnap-vault-config.yaml" ]; then
    echo "  - Creating qnap-vault-config.yaml..."
    cat > "$ROOT_DIR/manifests/core/vault/qnap-vault-config.yaml" <<EOF
# Auto-generated from environment variables - DO NOT COMMIT
apiVersion: v1
kind: ConfigMap
metadata:
  name: qnap-vault-config
  namespace: vault
data:
  config.yaml: |
    transit:
      address: "${QNAP_VAULT_ADDR:-http://nas.local:8200}"
      mountPath: "transit"
      keyName: "autounseal"
      tlsSkipVerify: true
EOF
fi

# External Secrets ClusterSecretStore
if [ ! -f "$ROOT_DIR/manifests/core/external-secrets-operator/clustersecretstore-nas-vault-backend.yaml" ]; then
    echo "  - Creating clustersecretstore-nas-vault-backend.yaml..."
    mkdir -p "$ROOT_DIR/manifests/core/external-secrets-operator"
    cat > "$ROOT_DIR/manifests/core/external-secrets-operator/clustersecretstore-nas-vault-backend.yaml" <<EOF
# Auto-generated from environment variables - DO NOT COMMIT
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: nas-vault-backend
spec:
  provider:
    vault:
      server: "${QNAP_VAULT_ADDR:-http://nas.local:8200}"
      path: "secret"
      version: "v2"
      auth:
        tokenSecretRef:
          name: "nas-vault-token"
          namespace: "external-secrets"
          key: "token"
EOF
fi

# Create ingress files for each app
echo "  - Creating ingress files..."
for app_dir in "$ROOT_DIR/manifests/core"/* "$ROOT_DIR/manifests/apps"/*; do
    if [ -d "$app_dir" ] && [ -f "$app_dir/ingress.yaml.tmpl" ]; then
        app_name=$(basename "$app_dir")
        echo "    - $app_name/ingress.yaml"
        envsubst < "$app_dir/ingress.yaml.tmpl" > "$app_dir/ingress.yaml"
    fi
done

echo ""
echo "✅ Local configuration created!"
echo ""
echo "📋 Next steps:"
echo "1. Review and edit .env if needed"
echo "2. Run 'task deploy' to deploy the cluster"
echo ""
echo "⚠️  Remember: These generated files are in .gitignore"
echo "   Never commit files with your actual domains/IPs!"