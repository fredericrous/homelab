#!/bin/bash
set -e

# QNAP K3s Services Deployment Script
echo "🚀 Deploying services to K3s on QNAP..."

# Configuration
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
KUBECONFIG_QNAP="${SCRIPT_DIR}/kubeconfig.yaml"
MANIFESTS_DIR="/Users/fredericrous/Developer/Perso/homelab/manifests/qnap"

# Check if kubeconfig exists
if [ ! -f "$KUBECONFIG_QNAP" ]; then
    echo "❌ QNAP kubeconfig not found at $KUBECONFIG_QNAP"
    exit 1
fi

export KUBECONFIG=$KUBECONFIG_QNAP

# Check K3s connectivity
echo "🔍 Checking K3s connectivity..."
if ! kubectl get nodes &>/dev/null; then
    echo "❌ Cannot connect to K3s cluster"
    exit 1
fi

echo "✅ Connected to K3s cluster"
kubectl get nodes

# Deploy base resources
echo "📦 Deploying base resources..."
kubectl apply -k ${MANIFESTS_DIR}/base

# Deploy Vault
echo "📦 Deploying Vault..."
kubectl kustomize ${MANIFESTS_DIR}/vault --enable-helm | kubectl apply -f -

# Wait for Vault to be ready
echo "⏳ Waiting for Vault to be ready..."
kubectl -n vault wait --for=condition=ready pod -l app.kubernetes.io/name=vault --timeout=300s

# Ensure MinIO namespace exists
kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f -

# Check if MinIO password secret exists
if ! kubectl -n minio get secret minio-root-user &>/dev/null 2>&1; then
    echo "🔐 Creating MinIO root user secret..."
    
    # Try to get password from Vault if available
    if [ -n "$VAULT_ADDR" ] && vault status &>/dev/null 2>&1 && vault kv get secret/minio &>/dev/null 2>&1; then
        echo "  Using password from Vault"
        MINIO_ROOT_PASSWORD=$(vault kv get -field=root_password secret/minio)
    else
        echo "  ⚠️  Vault not available, using default password"
        echo "     Run ./setup-vault-secrets.sh after Vault is ready to secure it"
        MINIO_ROOT_PASSWORD="changeme123"
    fi
    
    # Create MinIO root user secret
    kubectl -n minio create secret generic minio-root-user \
        --from-literal=rootUser=admin \
        --from-literal=rootPassword="$MINIO_ROOT_PASSWORD"
else
    echo "✅ MinIO root user secret already exists"
fi

# Deploy MinIO
echo "📦 Deploying MinIO..."
kubectl kustomize ${MANIFESTS_DIR}/minio --enable-helm | kubectl apply -f -

# Wait for MinIO to be ready
echo "⏳ Waiting for MinIO to be ready..."
kubectl -n minio wait --for=condition=ready pod -l app=minio --timeout=300s

# Post-deployment tasks
echo "🔧 Running post-deployment tasks..."

# Check if Vault is initialized and accessible
if kubectl -n vault get secret vault-keys &>/dev/null; then
    echo "✅ Vault is already initialized"
    
    # Try to setup Vault access if possible
    export VAULT_ADDR=http://192.168.1.42:61200
    if vault status &>/dev/null 2>&1; then
        echo "✅ Vault is accessible"
    else
        echo "⚠️  Vault is sealed or not accessible"
    fi
    
    # Check if AWS credentials secret exists
    if ! kubectl -n minio get secret aws-credentials &>/dev/null; then
        if vault kv get secret/velero &>/dev/null 2>&1; then
            echo "📦 Creating AWS credentials secret from Vault..."
            AWS_KEY=$(vault kv get -field=aws_access_key_id secret/velero)
            AWS_SECRET=$(vault kv get -field=aws_secret_access_key secret/velero)
            
            kubectl -n minio create secret generic aws-credentials \
                --from-literal=aws_access_key_id="$AWS_KEY" \
                --from-literal=aws_secret_access_key="$AWS_SECRET"
            echo "✅ AWS credentials secret created from Vault"
        else
            echo "⚠️  AWS credentials not in Vault. Run ./setup-vault-secrets.sh to configure"
        fi
    else
        echo "✅ AWS credentials secret already exists"
    fi
else
    echo "⚠️  Vault not initialized yet"
fi

echo ""
echo "✅ Deployment complete!"
echo ""
echo "📋 Service URLs:"
echo "  - Vault: http://192.168.1.42:61200"
echo "  - MinIO API: http://192.168.1.42:61900"
echo "  - MinIO Console: http://192.168.1.42:61901"
echo ""
echo "📦 MinIO credentials:"
echo "  Username: admin"
if [ -n "$VAULT_ADDR" ] && [ -n "$VAULT_TOKEN" ] && vault kv get secret/minio &>/dev/null 2>&1; then
    echo "  Password: (stored in Vault at secret/minio)"
    echo "  Retrieve: vault kv get -field=root_password secret/minio"
else
    echo "  Password: changeme123 (default - run setup-vault-secrets.sh to secure)"
fi
echo ""

if ! kubectl -n vault get secret vault-keys &>/dev/null; then
    echo "🔐 Initialize Vault (first time only):"
    echo "  export VAULT_ADDR=http://192.168.1.42:61200"
    echo "  vault operator init -key-shares=5 -key-threshold=3"
    echo "  # Save ALL 5 unseal keys and root token!"
    echo "  vault operator unseal <key-1>"
    echo "  vault operator unseal <key-2>"
    echo "  vault operator unseal <key-3>"
    echo "  vault login <root-token>"
    echo "  vault secrets enable -path=secret kv-v2"
    echo "  ./setup-vault-secrets.sh      # Setup MinIO password and AWS credentials"
    echo "  ./setup-vault-transit-k3s.sh  # Configure transit unseal for main K8s cluster"
    echo ""
fi

# Check if any required secrets are missing
MISSING_SECRETS=""
if ! kubectl -n minio get secret minio-root-user &>/dev/null 2>&1; then
    MISSING_SECRETS="MinIO password"
fi
if ! kubectl -n minio get secret aws-credentials &>/dev/null 2>&1; then
    if [ -n "$MISSING_SECRETS" ]; then
        MISSING_SECRETS="$MISSING_SECRETS and AWS credentials"
    else
        MISSING_SECRETS="AWS credentials"
    fi
fi

if [ -n "$MISSING_SECRETS" ]; then
    echo "⚠️  Missing secrets: $MISSING_SECRETS"
    echo "  Run: ./setup-vault-secrets.sh (after Vault is initialized)"
    echo ""
fi

# Remind about transit unseal setup
if kubectl -n vault get statefulset vault &>/dev/null && vault status &>/dev/null 2>&1; then
    if ! vault auth list | grep -q "approle/" &>/dev/null 2>&1; then
        echo "🔓 Transit unseal not configured yet"
        echo "  Run: ./setup-vault-transit-k3s.sh"
        echo "  This enables auto-unsealing for your main Kubernetes cluster"
        echo ""
    fi
fi

echo "📅 MinIO S3 sync cronjob:"
echo "  - Schedule: Every Sunday at 2 AM"
echo "  - Syncs to AWS S3 bucket: homelab-backups"
echo "  - Keeps only 7 most recent backups on S3"