#!/usr/bin/env zsh
set -e

echo "=== Checking Talos Cluster Status ==="
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# Check if we have the necessary files
if [ ! -f "./talosconfig" ]; then
    echo -e "${RED}Error: talosconfig not found${NC}"
    exit 1
fi

if [ ! -f "./kubeconfig" ]; then
    echo -e "${YELLOW}kubeconfig not found, trying to generate it...${NC}"
    terraform apply -target=talos_cluster_kubeconfig.this -auto-approve
fi

echo -e "${BLUE}1. Checking Talos node status...${NC}"
for ip in 192.168.1.67 192.168.1.68 192.168.1.69; do
    echo -n "  Node $ip: "
    if talosctl --talosconfig ./talosconfig --nodes $ip version >/dev/null 2>&1; then
        version=$(talosctl --talosconfig ./talosconfig --nodes $ip version --short | grep Server || echo "Unknown")
        echo -e "${GREEN}✓ Online${NC} - $version"
    else
        echo -e "${RED}✗ Offline${NC}"
    fi
done

echo ""
echo -e "${BLUE}2. Checking Kubernetes API...${NC}"
echo -n "  API Server: "
if timeout 5 nc -zv 192.168.1.67 6443 >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Port 6443 is open${NC}"
else
    echo -e "${YELLOW}⚠ Port 6443 not responding yet${NC}"
fi

echo ""
echo -e "${BLUE}3. Checking etcd status...${NC}"
talosctl --talosconfig ./talosconfig --nodes 192.168.1.67 etcd status || echo "Failed to get etcd status"

echo ""
echo -e "${BLUE}4. Checking services...${NC}"
talosctl --talosconfig ./talosconfig --nodes 192.168.1.67 services

echo ""
echo -e "${BLUE}5. Checking for any errors...${NC}"
talosctl --talosconfig ./talosconfig --nodes 192.168.1.67 logs kubelet | grep -i error | tail -5 || echo "No recent errors in kubelet"

echo ""
echo -e "${BLUE}6. Bootstrap status...${NC}"
talosctl --talosconfig ./talosconfig --nodes 192.168.1.67 bootstrap || echo "Cluster might already be bootstrapped"

# If kubeconfig exists, try kubectl
if [ -f "./kubeconfig" ]; then
    echo ""
    echo -e "${BLUE}7. Trying kubectl...${NC}"
    export KUBECONFIG=./kubeconfig
    if kubectl get nodes 2>/dev/null; then
        echo -e "${GREEN}✓ Kubernetes API is accessible!${NC}"
    else
        echo -e "${YELLOW}⚠ Kubernetes API not ready yet. This is normal during initial bootstrap.${NC}"
        echo "   Wait 2-3 minutes and try: kubectl get nodes"
    fi
fi

echo ""
echo -e "${YELLOW}Note: Initial cluster bootstrap can take 3-5 minutes.${NC}"
echo "You can monitor progress with:"
echo "  talosctl --talosconfig ./talosconfig --nodes 192.168.1.67 logs kubelet -f"