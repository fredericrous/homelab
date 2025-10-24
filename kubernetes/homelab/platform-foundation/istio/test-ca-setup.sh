#!/bin/bash
set -e

echo "🔍 Testing Istio CA Setup"
echo "========================"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to check if resource exists
check_resource() {
    local kubeconfig=$1
    local resource=$2
    local name=$3
    local namespace=$4
    
    if kubectl --kubeconfig "$kubeconfig" get "$resource" "$name" -n "$namespace" &>/dev/null; then
        echo -e "${GREEN}✅ $resource/$name exists in $namespace${NC}"
        return 0
    else
        echo -e "${RED}❌ $resource/$name NOT FOUND in $namespace${NC}"
        return 1
    fi
}

echo -e "\n${YELLOW}1. Checking Homelab CA Bootstrap Job${NC}"
check_resource "kubeconfig" "job" "istio-ca-bootstrap" "istio-system"

echo -e "\n${YELLOW}2. Checking Homelab ExternalSecret${NC}"
check_resource "kubeconfig" "externalsecret" "istio-cacerts" "istio-system"

echo -e "\n${YELLOW}3. Checking Homelab cacerts Secret${NC}"
if check_resource "kubeconfig" "secret" "cacerts" "istio-system"; then
    # Verify it has the required keys
    for key in root-cert.pem cert-chain.pem key.pem; do
        if kubectl --kubeconfig kubeconfig get secret cacerts -n istio-system -o jsonpath="{.data.$key}" | grep -q .; then
            echo -e "  ${GREEN}✅ Key $key exists${NC}"
        else
            echo -e "  ${RED}❌ Key $key missing${NC}"
        fi
    done
fi

echo -e "\n${YELLOW}4. Checking NAS SecretStore${NC}"
check_resource "infrastructure/nas/kubeconfig.yaml" "secretstore" "istio-ca-vault" "istio-system"

echo -e "\n${YELLOW}5. Checking NAS ExternalSecret${NC}"
check_resource "infrastructure/nas/kubeconfig.yaml" "externalsecret" "istio-cacerts" "istio-system"

echo -e "\n${YELLOW}6. Checking NAS cacerts Secret${NC}"
if check_resource "infrastructure/nas/kubeconfig.yaml" "secret" "cacerts" "istio-system"; then
    # Verify it has the required keys
    for key in root-cert.pem cert-chain.pem key.pem; do
        if kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml get secret cacerts -n istio-system -o jsonpath="{.data.$key}" | grep -q .; then
            echo -e "  ${GREEN}✅ Key $key exists${NC}"
        else
            echo -e "  ${RED}❌ Key $key missing${NC}"
        fi
    done
fi

echo -e "\n${YELLOW}7. Comparing CA Fingerprints${NC}"
if kubectl --kubeconfig kubeconfig get secret cacerts -n istio-system &>/dev/null && \
   kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml get secret cacerts -n istio-system &>/dev/null; then
    
    HOMELAB_CA_FP=$(kubectl --kubeconfig kubeconfig -n istio-system get secret cacerts -o jsonpath='{.data.root-cert\.pem}' | base64 -d | openssl x509 -fingerprint -noout 2>/dev/null || echo "FAILED")
    NAS_CA_FP=$(kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml -n istio-system get secret cacerts -o jsonpath='{.data.root-cert\.pem}' | base64 -d | openssl x509 -fingerprint -noout 2>/dev/null || echo "FAILED")
    
    if [ "$HOMELAB_CA_FP" = "$NAS_CA_FP" ] && [ "$HOMELAB_CA_FP" != "FAILED" ]; then
        echo -e "${GREEN}✅ Both clusters share the same CA${NC}"
        echo "   Fingerprint: $HOMELAB_CA_FP"
    else
        echo -e "${RED}❌ CA mismatch between clusters!${NC}"
        echo "   Homelab: $HOMELAB_CA_FP"
        echo "   NAS:     $NAS_CA_FP"
    fi
else
    echo -e "${YELLOW}⚠️  Cannot compare - one or both secrets missing${NC}"
fi

echo -e "\n${GREEN}✨ Test complete!${NC}"