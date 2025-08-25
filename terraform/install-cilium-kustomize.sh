#!/bin/bash

echo "=== Installing Cilium CNI with Kustomize ==="
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# Check if we have kubeconfig
if [ ! -f "./kubeconfig" ]; then
    echo -e "${RED}Error: kubeconfig not found${NC}"
    exit 1
fi

export KUBECONFIG=./kubeconfig

# Check cluster is accessible
echo -e "${BLUE}Checking cluster access...${NC}"
kubectl cluster-info

echo ""
echo -e "${BLUE}Current node status:${NC}"
kubectl get nodes

# Check if kustomize is available
if ! command -v kustomize >/dev/null 2>&1; then
    # Check if kubectl has kustomize built-in
    if ! kubectl kustomize --help >/dev/null 2>&1; then
        echo -e "${RED}Error: kustomize not found${NC}"
        echo "Install with: brew install kustomize"
        exit 1
    fi
    echo -e "${YELLOW}Using kubectl's built-in kustomize${NC}"
    KUSTOMIZE_CMD="kubectl kustomize"
else
    echo -e "${GREEN}Using standalone kustomize${NC}"
    KUSTOMIZE_CMD="kustomize"
fi

echo ""
echo -e "${BLUE}Building Cilium manifests with Kustomize...${NC}"

# Change to the cilium directory
cd ../manifests/cilium || {
    echo -e "${RED}Error: Could not find manifests/cilium directory${NC}"
    exit 1
}

# Build the manifests
echo "Building from $(pwd)..."
if [ "$KUSTOMIZE_CMD" = "kustomize" ]; then
    # Standalone kustomize with helm enabled
    $KUSTOMIZE_CMD build --enable-helm . > /tmp/cilium-manifest.yaml
else
    # kubectl kustomize doesn't support --enable-helm, need to use different approach
    echo -e "${YELLOW}kubectl kustomize doesn't support Helm charts${NC}"
    echo -e "${YELLOW}Switching to direct Helm installation${NC}"
    
    # Check if helm is installed
    if ! command -v helm >/dev/null 2>&1; then
        echo -e "${RED}Error: helm not found. Install with: brew install helm${NC}"
        exit 1
    fi
    
    # Add Cilium repo and install
    helm repo add cilium https://helm.cilium.io/
    helm repo update
    
    echo -e "${BLUE}Installing Cilium with Helm...${NC}"
    helm upgrade --install cilium cilium/cilium \
        --version 1.15.6 \
        --namespace kube-system \
        --values values.talos.yaml \
        --wait
    
    # Skip the rest of the kustomize process
    cd - > /dev/null
    skip_apply=true
fi

if [ "$skip_apply" != "true" ]; then
    if [ ! -s /tmp/cilium-manifest.yaml ]; then
        echo -e "${RED}Error: Failed to build Cilium manifests${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ Manifests built successfully${NC}"

    # Return to terraform directory
    cd - > /dev/null

    echo ""
    echo -e "${BLUE}Applying Cilium manifests...${NC}"
    kubectl apply -f /tmp/cilium-manifest.yaml
fi

echo ""
echo -e "${BLUE}Waiting for Cilium to be ready...${NC}"
echo "This may take 2-3 minutes..."

# Wait for Cilium operator
echo -n "Waiting for Cilium operator..."
kubectl -n kube-system wait --for=condition=ready pod -l name=cilium-operator --timeout=300s || {
    echo -e "${YELLOW}Warning: Cilium operator not ready yet${NC}"
}

# Wait for Cilium agents
echo -n "Waiting for Cilium agents..."
kubectl -n kube-system wait --for=condition=ready pod -l k8s-app=cilium --timeout=300s || {
    echo -e "${YELLOW}Warning: Cilium agents not ready yet${NC}"
}

echo ""
echo -e "${BLUE}Cilium pod status:${NC}"
kubectl -n kube-system get pods | grep cilium

echo ""
echo -e "${BLUE}Checking node status (should transition to Ready)...${NC}"
# Check nodes multiple times
for i in {1..10}; do
    kubectl get nodes
    
    # Check if all nodes are ready
    ready_nodes=$(kubectl get nodes --no-headers | grep -c " Ready ")
    total_nodes=$(kubectl get nodes --no-headers | wc -l)
    
    if [ "$ready_nodes" -eq "$total_nodes" ] && [ "$total_nodes" -gt 0 ]; then
        echo ""
        echo -e "${GREEN}✓ All nodes are Ready! ($ready_nodes/$total_nodes)${NC}"
        break
    else
        echo -e "${YELLOW}Nodes ready: $ready_nodes/$total_nodes${NC}"
    fi
    
    if [ $i -lt 10 ]; then
        echo "Waiting 15 seconds..."
        sleep 15
    fi
done

# Clean up
rm -f /tmp/cilium-manifest.yaml

echo ""
echo -e "${GREEN}Cilium installation complete!${NC}"
echo ""

# Show final status
echo -e "${BLUE}Final cluster status:${NC}"
kubectl get nodes
echo ""
kubectl -n kube-system get pods | grep cilium

echo ""
echo "Monitor Cilium with:"
echo "  kubectl -n kube-system logs -l k8s-app=cilium -f"
echo "  kubectl -n kube-system get pods -w"

# If cilium CLI is available, show status
if command -v cilium >/dev/null 2>&1; then
    echo ""
    echo -e "${BLUE}Cilium connectivity status:${NC}"
    cilium status --wait
fi