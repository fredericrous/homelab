#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "🔍 Testing Istio CA Setup"
echo "========================"

# Function to check if a resource exists
check_resource() {
    local resource_type=$1
    local resource_name=$2
    local namespace=$3
    local kubeconfig=${4:-"kubeconfig"}
    
    if kubectl --kubeconfig "$kubeconfig" get "$resource_type" "$resource_name" -n "$namespace" &>/dev/null; then
        echo -e "${GREEN}✅ $resource_type/$resource_name exists in namespace $namespace${NC}"
        return 0
    else
        echo -e "${RED}❌ $resource_type/$resource_name NOT FOUND in namespace $namespace${NC}"
        return 1
    fi
}

# Function to verify secret content
verify_secret_content() {
    local secret_name=$1
    local namespace=$2
    local expected_keys=$3
    local kubeconfig=${4:-"kubeconfig"}
    
    echo -e "\n${YELLOW}Checking secret $secret_name in namespace $namespace...${NC}"
    
    for key in $expected_keys; do
        if kubectl --kubeconfig "$kubeconfig" get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.$key}" | base64 -d &>/dev/null; then
            echo -e "${GREEN}✅ Key '$key' exists and contains valid data${NC}"
        else
            echo -e "${RED}❌ Key '$key' missing or invalid${NC}"
            return 1
        fi
    done
}

# Function to test Vault connectivity
test_vault_connectivity() {
    local vault_url=$1
    local test_name=$2
    local kubeconfig=${3:-"kubeconfig"}
    
    echo -e "\n${YELLOW}Testing Vault connectivity: $test_name${NC}"
    
    kubectl --kubeconfig "$kubeconfig" -n istio-system run vault-test-$RANDOM --rm -it --restart=Never \
        --image=curlimages/curl --command -- sh -c \
        "curl -sS -m 5 $vault_url/v1/sys/health | grep -q initialized && echo 'SUCCESS' || echo 'FAILED'" 2>/dev/null | grep -q SUCCESS
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Vault is reachable at $vault_url${NC}"
        return 0
    else
        echo -e "${RED}❌ Cannot reach Vault at $vault_url${NC}"
        return 1
    fi
}

echo -e "\n${YELLOW}Step 1: Verify CA Generation Job${NC}"
echo "--------------------------------"
check_resource job istio-ca-setup istio-system

echo -e "\n${YELLOW}Step 2: Verify Homelab Cluster Resources${NC}"
echo "----------------------------------------"
check_resource externalsecret istio-cacerts istio-system
check_resource secret cacerts istio-system
verify_secret_content cacerts istio-system "root-cert.pem cert-chain.pem root-key.pem"

echo -e "\n${YELLOW}Step 3: Verify NAS Cluster Resources${NC}"
echo "------------------------------------"
check_resource secretstore vault-backend-homelab istio-system "infrastructure/nas/kubeconfig.yaml"
check_resource externalsecret istio-cacerts istio-system "infrastructure/nas/kubeconfig.yaml"
check_resource secret cacerts istio-system "infrastructure/nas/kubeconfig.yaml"
verify_secret_content cacerts istio-system "root-cert.pem cert-chain.pem root-key.pem" "infrastructure/nas/kubeconfig.yaml"

echo -e "\n${YELLOW}Step 4: Verify Shared CA${NC}"
echo "------------------------"
echo "Comparing CA fingerprints between clusters..."

HOMELAB_CA_HASH=$(kubectl --kubeconfig kubeconfig -n istio-system get secret cacerts -o jsonpath='{.data.root-cert\.pem}' | base64 -d | openssl x509 -fingerprint -noout | cut -d= -f2)
NAS_CA_HASH=$(kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml -n istio-system get secret cacerts -o jsonpath='{.data.root-cert\.pem}' | base64 -d | openssl x509 -fingerprint -noout | cut -d= -f2)

if [ "$HOMELAB_CA_HASH" == "$NAS_CA_HASH" ]; then
    echo -e "${GREEN}✅ Both clusters share the same CA (fingerprint: $HOMELAB_CA_HASH)${NC}"
else
    echo -e "${RED}❌ CA mismatch between clusters!${NC}"
    echo "   Homelab: $HOMELAB_CA_HASH"
    echo "   NAS:     $NAS_CA_HASH"
fi

echo -e "\n${YELLOW}Step 5: Test East-West Gateway${NC}"
echo "-------------------------------"
check_resource pod -l app=istio-eastwestgateway istio-system "infrastructure/nas/kubeconfig.yaml"

echo -e "\n${YELLOW}Step 6: Test Vault Connectivity via Istio${NC}"
echo "-----------------------------------------"
test_vault_connectivity "http://vault-vault-nas.vault.svc.cluster.local:8200" "NAS Vault via Istio"

echo -e "\n${YELLOW}Step 7: Verification Commands${NC}"
echo "-----------------------------"
echo "Run these commands to perform additional checks:"
echo ""
echo "# Reconcile Istio installations:"
echo "flux --kubeconfig kubeconfig reconcile helmrelease istio-base -n flux-system"
echo "flux --kubeconfig kubeconfig reconcile helmrelease istiod -n flux-system" 
echo "flux --kubeconfig kubeconfig reconcile helmrelease istio-eastwestgateway -n flux-system"
echo ""
echo "flux --kubeconfig infrastructure/nas/kubeconfig.yaml reconcile helmrelease istio-base -n flux-system"
echo "flux --kubeconfig infrastructure/nas/kubeconfig.yaml reconcile helmrelease istiod -n flux-system"
echo "flux --kubeconfig infrastructure/nas/kubeconfig.yaml reconcile helmrelease istio-eastwestgateway -n flux-system"
echo ""
echo "# Check Istio injection webhook:"
echo "kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml get mutatingwebhookconfigurations -l app=sidecar-injector"
echo ""
echo "# Test a pod with injection:"
echo "kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml -n default run test-injection --image=nginx --dry-run=server -o yaml | grep -A5 istio"

echo -e "\n${GREEN}✅ Test script complete!${NC}"