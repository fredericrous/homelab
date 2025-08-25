#!/bin/bash
set -e

echo "=== Deploying Homelab Manifests with Kustomize ==="
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

export KUBECONFIG=/Users/fredericrous/Developer/Perso/homelab/terraform/kubeconfig
MANIFESTS_DIR="/Users/fredericrous/Developer/Perso/homelab/manifests"

# Function to deploy a manifest
deploy_manifest() {
    local name=$1
    local wait_for=$2
    local namespace=$3

    echo ""
    echo -e "${BLUE}Deploying $name...${NC}"

    cd "$MANIFESTS_DIR/$name"

    # Check if kustomization.yaml exists
    if [ ! -f "kustomization.yaml" ]; then
        echo -e "${RED}Error: No kustomization.yaml found in $name${NC}"
        return 1
    fi

    # Check if it uses Helm charts
    if grep -q "helmCharts:" kustomization.yaml; then
        echo -e "${YELLOW}Building with --enable-helm flag${NC}"
        kustomize build --enable-helm . | kubectl apply -f -
    else
        kustomize build . | kubectl apply -f -
    fi

    # Wait for deployment if specified
    if [ -n "$wait_for" ] && [ -n "$namespace" ]; then
        echo -e "${YELLOW}Waiting for $wait_for to be ready...${NC}"
        kubectl -n "$namespace" wait --for=condition=ready pod -l "$wait_for" --timeout=300s || {
            echo -e "${YELLOW}Warning: Some pods not ready yet${NC}"
        }
    fi

    echo -e "${GREEN}✓ $name deployed${NC}"
}

# List of manifests to deploy in order
echo -e "${BLUE}Deployment order:${NC}"
echo "1. coredns (already deployed)"
echo "2. rook-ceph (in progress)"
echo "3. csi-driver-nfs"
echo "4. metallb"
echo "5. redis"
echo "6. cloudnative-pg"
echo "7. cert-manager"
echo "8. haproxy-ingress"
echo "9. node-feature-discovery"
echo "10. nvidia-device-plugin"
echo ""

# Check if rook-ceph is ready
echo -e "${BLUE}Checking rook-ceph status...${NC}"
kubectl -n rook-ceph get pods

# Deploy remaining manifests
deploy_manifest "csi-driver-nfs" "" ""

deploy_manifest "metallb" "app=metallb" "metallb-system"

deploy_manifest "redis" "" ""

deploy_manifest "cloudnative-pg" "app.kubernetes.io/name=cloudnative-pg" "cnpg-system"

deploy_manifest "cert-manager" "app=cert-manager" "cert-manager"

deploy_manifest "haproxy-ingress" "app.kubernetes.io/name=haproxy-ingress" "haproxy-ingress"

deploy_manifest "node-feature-discovery" "app=node-feature-discovery" "node-feature-discovery"

deploy_manifest "nvidia-device-plugin" "name=nvidia-device-plugin-ds" "nvidia-device-plugin"

echo ""
echo -e "${GREEN}All manifests deployed!${NC}"
echo ""
echo "Check deployment status:"
echo "  kubectl get pods -A"
echo ""
echo "Check storage classes:"
echo "  kubectl get storageclass"
