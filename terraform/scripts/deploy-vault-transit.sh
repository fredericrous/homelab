#!/bin/bash
set -e

# Deploy Vault with Transit Unseal
echo "🔐 Deploying Vault with Transit Unseal"
echo "======================================"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Accept kubeconfig as parameter or use default
if [ -n "$1" ]; then
    export KUBECONFIG="$1"
    echo "Using kubeconfig: $KUBECONFIG"
fi

# Check if we have kubeconfig
if ! kubectl cluster-info &>/dev/null; then
    echo -e "${RED}❌ Cannot connect to Kubernetes cluster${NC}"
    echo "   Ensure your kubeconfig is set up correctly"
    exit 1
fi

# Function to get transit token
get_transit_token() {
    echo -e "${YELLOW}📋 Transit Token Setup${NC}"
    echo "========================"
    
    # Check if token already exists in cluster
    if kubectl get secret vault-transit-token -n vault &>/dev/null 2>&1; then
        echo -e "${GREEN}✅ Transit token secret already exists${NC}"
        return 0
    fi
    
    # Check environment variable (should always exist due to Taskfile prereq check)
    if [ -n "${K8S_VAULT_TRANSIT_TOKEN:-}" ]; then
        echo -e "${GREEN}✅ Found transit token in environment${NC}"
        return 0
    fi
    
    # Check if we can get it from QNAP
    echo -e "${YELLOW}🔍 Checking for QNAP Vault access...${NC}"
    if command -v vault &>/dev/null && [ -n "$VAULT_ADDR" ]; then
        # Try to read from QNAP Vault
        if vault read -field=k8s_transit_token secret/transit-tokens &>/dev/null 2>&1; then
            K8S_VAULT_TRANSIT_TOKEN=$(vault read -field=k8s_transit_token secret/transit-tokens)
            echo -e "${GREEN}✅ Retrieved transit token from QNAP Vault${NC}"
            return 0
        fi
    fi
    
    # This should not happen if called from Taskfile
    echo -e "${RED}❌ Transit token not found!${NC}"
    echo "This script expects K8S_VAULT_TRANSIT_TOKEN to be set."
    echo "Please run: task deploy (or task stage7)"
    exit 1
}

# Main deployment
echo -e "${YELLOW}🚀 Starting Vault deployment${NC}"

# Create namespace
echo "📦 Creating namespace..."
kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -

# Get transit token
get_transit_token

# Create transit token secret
if ! kubectl get secret vault-transit-token -n vault &>/dev/null 2>&1; then
    echo "🔑 Creating transit token secret..."
    kubectl create secret generic vault-transit-token \
        --namespace=vault \
        --from-literal=token="$K8S_VAULT_TRANSIT_TOKEN"
    echo -e "${GREEN}✅ Transit token secret created${NC}"
fi

# Note: Vault will be deployed via ArgoCD ApplicationSet
echo -e "${YELLOW}📋 Vault deployment note:${NC}"
echo "   Vault will be automatically deployed by ArgoCD ApplicationSet"
echo "   The terraform deployment will sync it in the next stage"

# Wait for Vault to be ready
echo "⏳ Waiting for Vault pod..."
kubectl wait --for=condition=Ready pod -l app=vault -n vault --timeout=300s 2>/dev/null || {
    echo -e "${YELLOW}⚠️  Vault pod not ready yet${NC}"
    echo "Check deployment with: kubectl get pods -n vault"
    exit 0
}

# Check Vault status
echo "🔍 Checking Vault status..."
kubectl exec -n vault vault-0 -- vault status || true

# Get admin token if initialized
if kubectl get secret vault-admin-token -n vault &>/dev/null 2>&1; then
    echo ""
    echo -e "${GREEN}✅ Vault deployment complete!${NC}"
    echo ""
    echo "📋 Access Vault:"
    echo "  kubectl port-forward -n vault svc/vault 8200:8200"
    echo "  export VAULT_ADDR=http://127.0.0.1:8200"
    echo "  export VAULT_TOKEN=\$(kubectl get secret vault-admin-token -n vault -o jsonpath='{.data.token}' | base64 -d)"
    echo "  vault status"
else
    echo ""
    echo -e "${YELLOW}⏳ Vault initialization pending${NC}"
    echo "The init job will run automatically via ArgoCD"
fi

echo ""
echo -e "${GREEN}✅ Transit token configured!${NC}"
echo "   Vault will be deployed and initialized in the next terraform stage"

# Exit with success - let terraform continue
exit 0