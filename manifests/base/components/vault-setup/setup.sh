#!/bin/sh
set -e

echo "🔐 Setting up Vault secrets for ${APP_NAME}..."

# Wait for Vault to be ready
until vault status | grep -q "Sealed.*false"; do
  echo "Waiting for Vault to be unsealed..."
  sleep 5
done
echo "✅ Vault is ready"

# Function to generate secure random string
generate_secret() {
  head -c 32 /dev/urandom | base64 | tr -d '\n'
}

# Check if secrets already exist
if vault kv get -mount=secret ${APP_NAME} > /dev/null 2>&1; then
  echo "✅ ${APP_NAME} secrets already exist in Vault"
else
  echo "📝 Creating ${APP_NAME} secrets in Vault"
  
  # Generate default secrets (apps can override in their own setup)
  vault kv put -mount=secret ${APP_NAME} \
    JWT_SECRET=$(generate_secret) \
    SESSION_SECRET=$(generate_secret) \
    ENCRYPTION_KEY=$(generate_secret)
fi

# Create Vault policy for the app
echo "📝 Creating ${APP_NAME} Vault policy"
vault policy write ${APP_NAME}-policy - <<EOF
path "secret/data/${APP_NAME}" {
  capabilities = ["read"]
}
path "secret/data/${APP_NAME}/*" {
  capabilities = ["read"]
}
EOF

# Create Kubernetes auth role
echo "📝 Creating ${APP_NAME} Kubernetes auth role"
vault write auth/kubernetes/role/${APP_NAME} \
  bound_service_account_names=${SERVICE_ACCOUNT:-default} \
  bound_service_account_namespaces=${APP_NAME} \
  policies=${APP_NAME}-policy \
  ttl=24h

echo "✅ ${APP_NAME} Vault setup complete!"