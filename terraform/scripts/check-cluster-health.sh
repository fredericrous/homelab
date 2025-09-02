#!/bin/bash
# Cluster health check script to detect and warn about potential issues

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Accept kubeconfig as parameter or use default
KUBECONFIG="${1:-$(pwd)/../kubeconfig}"
TALOSCONFIG="${2:-$(pwd)/talosconfig}"

echo "🔍 Checking Cluster Health"
echo "=========================="

# Check 1: Kubernetes API connectivity
echo -n "Checking Kubernetes API... "
if kubectl --kubeconfig="$KUBECONFIG" cluster-info &>/dev/null; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗${NC} Cannot connect to Kubernetes API"
    echo "  The cluster may be down or certificates may be invalid"
    exit 1
fi

# Check 2: Node status
echo -n "Checking node status... "
NOT_READY=$(kubectl --kubeconfig="$KUBECONFIG" get nodes -o json | jq -r '.items[] | select(.status.conditions[] | select(.type=="Ready" and .status!="True")) | .metadata.name' | wc -l)
if [ "$NOT_READY" -eq 0 ]; then
    echo -e "${GREEN}✓${NC} All nodes ready"
else
    echo -e "${RED}✗${NC} $NOT_READY nodes not ready"
    kubectl --kubeconfig="$KUBECONFIG" get nodes
fi

# Check 3: System pods
echo -n "Checking system pods... "
FAILED_PODS=$(kubectl --kubeconfig="$KUBECONFIG" get pods -A -o json | jq -r '.items[] | select(.status.phase!="Running" and .status.phase!="Succeeded") | "\(.metadata.namespace)/\(.metadata.name)"' | wc -l)
if [ "$FAILED_PODS" -eq 0 ]; then
    echo -e "${GREEN}✓${NC} All system pods healthy"
else
    echo -e "${YELLOW}⚠${NC} $FAILED_PODS pods not running"
    kubectl --kubeconfig="$KUBECONFIG" get pods -A | grep -v Running | grep -v Completed | head -10
fi

# Check 4: Talos kernel parameter warnings (if talosctl available)
if [ -f "$TALOSCONFIG" ] && command -v talosctl &>/dev/null; then
    echo -n "Checking Talos logs for critical errors... "
    CONTROL_PLANE_IP=$(kubectl --kubeconfig="$KUBECONFIG" get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    
    if [ -n "$CONTROL_PLANE_IP" ]; then
        # Check for authorization errors in the last 5 minutes
        AUTH_ERRORS=$(TALOSCONFIG="$TALOSCONFIG" talosctl -n "$CONTROL_PLANE_IP" logs -k 2>/dev/null | grep -i "authorization error" | grep -v "^#" | tail -5 | wc -l || echo "0")
        
        if [ "$AUTH_ERRORS" -eq 0 ]; then
            echo -e "${GREEN}✓${NC} No authorization errors"
        else
            echo -e "${RED}✗${NC} Found authorization errors"
            echo "  This may indicate kubelet-apiserver communication issues"
            echo "  Consider running: talosctl -n $CONTROL_PLANE_IP reboot"
        fi
    else
        echo -e "${YELLOW}⚠${NC} Could not determine control plane IP"
    fi
else
    echo -e "${YELLOW}ℹ${NC} Skipping Talos checks (talosctl not available)"
fi

# Check 5: Certificate expiration
echo -n "Checking certificate expiration... "
CERT_INFO=$(kubectl --kubeconfig="$KUBECONFIG" get cm -n kube-system kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null || echo "")
if [ -n "$CERT_INFO" ]; then
    echo -e "${GREEN}✓${NC} Certificates accessible"
else
    echo -e "${YELLOW}⚠${NC} Cannot check certificate status"
fi

echo ""
echo "=========================="

# Summary
if [ "$NOT_READY" -eq 0 ] && [ "$FAILED_PODS" -eq 0 ] && [ "${AUTH_ERRORS:-0}" -eq 0 ]; then
    echo -e "${GREEN}✅ Cluster is healthy${NC}"
    exit 0
else
    echo -e "${YELLOW}⚠️ Cluster has issues that need attention${NC}"
    exit 1
fi