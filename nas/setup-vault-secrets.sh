#!/bin/bash
set -e

# Setup Vault secrets for MinIO and AWS
echo "🔐 Setting up Vault secrets for QNAP services..."

# Check if Vault is accessible
export VAULT_ADDR=http://192.168.1.42:61200
if ! vault status &>/dev/null; then
    echo "❌ Vault is not accessible at $VAULT_ADDR"
    echo "   Make sure Vault is unsealed and you're logged in"
    exit 1
fi

# Check if we're authenticated
if ! vault token lookup &>/dev/null; then
    echo "❌ Not authenticated to Vault"
    echo "   Run: vault login <root-token>"
    exit 1
fi

# Check if secret engine is enabled
if ! vault secrets list | grep -q "^secret/"; then
    echo "📦 Enabling KV v2 secrets engine..."
    vault secrets enable -path=secret kv-v2
fi

# Check if MinIO password already exists in Vault
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

# Store in Vault
echo "💾 Storing MinIO credentials in Vault..."
vault kv put secret/minio \
    root_user=admin \
    root_password="$MINIO_ROOT_PASSWORD"

echo "✅ MinIO credentials stored in Vault at secret/minio"

# Check if MinIO is already deployed
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export KUBECONFIG="${SCRIPT_DIR}/kubeconfig.yaml"

if kubectl get deployment minio -n minio &>/dev/null 2>&1; then
    echo ""
    echo "⚠️  MinIO is already deployed. To update the password:"
    echo ""
    echo "1. Update the Kubernetes secret:"
    echo "   kubectl -n minio create secret generic minio-root-user \\"
    echo "     --from-literal=rootUser=admin \\"
    echo "     --from-literal=rootPassword='$MINIO_ROOT_PASSWORD' \\"
    echo "     --dry-run=client -o yaml | kubectl apply -f -"
    echo ""
    echo "2. Restart MinIO to pick up the new password:"
    echo "   kubectl -n minio rollout restart deployment minio"
    echo ""
    echo "3. Update any scripts or configurations using the old password"
else
    echo ""
    echo "✅ MinIO password is ready for deployment"
    echo "   The deploy script will use this password automatically"
fi

# Setup AWS credentials for S3 sync
echo ""
echo "☁️  Setting up AWS credentials for S3 sync..."

# Check if AWS credentials already exist in Vault
if vault kv get secret/velero &>/dev/null 2>&1; then
    echo "✅ AWS credentials already exist in Vault"
    echo "   Update them? (y/N): "
    read -r UPDATE_AWS
    if [[ ! "$UPDATE_AWS" =~ ^[Yy]$ ]]; then
        AWS_SETUP_DONE=true
    fi
fi

if [ -z "$AWS_SETUP_DONE" ]; then
    # Check for AWS credentials in environment
    if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ]; then
        echo "📦 Found AWS credentials in environment variables"
        echo "   Use these credentials? (Y/n): "
        read -r USE_ENV_AWS
        if [[ ! "$USE_ENV_AWS" =~ ^[Nn]$ ]]; then
            vault kv put secret/velero \
                aws_access_key_id="$AWS_ACCESS_KEY_ID" \
                aws_secret_access_key="$AWS_SECRET_ACCESS_KEY"
            echo "✅ AWS credentials stored in Vault"
            AWS_SETUP_DONE=true
        fi
    fi
    
    if [ -z "$AWS_SETUP_DONE" ]; then
        echo "🔑 Enter AWS credentials for S3 backup sync:"
        echo -n "   AWS Access Key ID: "
        read -r AWS_ACCESS_KEY_ID
        echo -n "   AWS Secret Access Key: "
        read -rs AWS_SECRET_ACCESS_KEY
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

# Create Kubernetes secret for MinIO if deployed
if kubectl get deployment minio -n minio &>/dev/null 2>&1; then
    echo ""
    echo "📦 Creating Kubernetes secrets..."
    
    # Create AWS credentials secret
    if vault kv get secret/velero &>/dev/null 2>&1; then
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

if ! kubectl get deployment minio -n minio &>/dev/null 2>&1; then
    echo "💡 MinIO not deployed yet. Run ./deploy-k3s-services.sh to deploy."
fi