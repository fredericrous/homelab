#!/bin/bash

echo "=== Diagnosing Node Issues ==="
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# Set kubeconfig
export KUBECONFIG=./kubeconfig

echo -e "${BLUE}1. Node Status:${NC}"
kubectl get nodes -o wide

echo ""
echo -e "${BLUE}2. Checking kubelet on control plane:${NC}"
talosctl --talosconfig ./talosconfig --nodes 192.168.1.67 service kubelet status

echo ""
echo -e "${BLUE}3. Recent kubelet logs:${NC}"
talosctl --talosconfig ./talosconfig --nodes 192.168.1.67 logs kubelet | tail -20

echo ""
echo -e "${BLUE}4. Node conditions:${NC}"
kubectl describe node talos-cp-1 | grep -A10 "Conditions:"

echo ""
echo -e "${BLUE}5. Cilium status:${NC}"
kubectl -n kube-system get pods -l k8s-app=cilium -o wide

echo ""
echo -e "${BLUE}6. Check CNI configuration:${NC}"
talosctl --talosconfig ./talosconfig --nodes 192.168.1.67 ls /etc/cni/net.d/

echo ""
echo -e "${BLUE}7. System pods in kube-system:${NC}"
kubectl -n kube-system get pods

echo ""
echo -e "${BLUE}8. Check for network-related errors:${NC}"
kubectl -n kube-system logs -l k8s-app=cilium --tail=10 | grep -i error || echo "No recent errors in Cilium logs"

echo ""
echo -e "${BLUE}9. Talos network configuration:${NC}"
talosctl --talosconfig ./talosconfig --nodes 192.168.1.67 get nodenames

echo ""
echo -e "${YELLOW}To continuously monitor node status:${NC}"
echo "  export KUBECONFIG=./kubeconfig"
echo "  kubectl get nodes -w"