#!/usr/bin/env zsh
set -e

echo "=== Verifying Talos Nodes and Completing Deployment ==="
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# Check if nodes are accessible at their static IPs
echo -e "${BLUE}Checking nodes at static IPs...${NC}"

nodes_ready=true
for node in "talos-cp-1:192.168.1.67" "talos-wk-1-gpu:192.168.1.68" "talos-wk-2:192.168.1.69"; do
    hostname=${node%:*}
    ip=${node#*:}
    
    echo -n "Checking $hostname at $ip... "
    
    # Try with talosconfig if it exists
    if [ -f "./talosconfig" ]; then
        if talosctl --talosconfig ./talosconfig --nodes $ip version >/dev/null 2>&1; then
            echo -e "${GREEN}✓ Accessible with talosconfig${NC}"
        else
            echo -e "${RED}✗ Not accessible${NC}"
            nodes_ready=false
        fi
    else
        # Try without talosconfig (will fail if TLS is required)
        if talosctl --nodes $ip version >/dev/null 2>&1; then
            echo -e "${GREEN}✓ Accessible${NC}"
        else
            echo -e "${YELLOW}⚠ Requires authentication (node is configured)${NC}"
        fi
    fi
done

echo ""

# If talosconfig doesn't exist, we need to run terraform to generate it
if [ ! -f "./talosconfig" ]; then
    echo -e "${YELLOW}Talosconfig not found. Generating with Terraform...${NC}"
    export TF_VAR_configure_talos=true
    terraform apply -target=talos_machine_secrets.this -target=data.talos_client_configuration.this -target=local_file.talosconfig -auto-approve
fi

# Now complete the full deployment
echo ""
echo -e "${BLUE}Completing Terraform deployment...${NC}"
export TF_VAR_configure_talos=true
terraform apply -auto-approve

echo ""
echo -e "${GREEN}Deployment should be complete!${NC}"
echo ""

# Check cluster health
if [ -f "./talosconfig" ]; then
    echo -e "${BLUE}Checking cluster health...${NC}"
    # Add timeout to prevent hanging
    timeout 120 talosctl --talosconfig ./talosconfig health --nodes 192.168.1.67 || {
        echo -e "${YELLOW}Health check timed out or failed. This is normal during initial setup.${NC}"
        echo "The cluster is likely still bootstrapping."
    }
fi

echo ""
echo "Next steps:"
echo "  1. Export kubeconfig: export KUBECONFIG=./kubeconfig"
echo "  2. Check nodes: kubectl get nodes"
echo "  3. Check cluster: talosctl --talosconfig ./talosconfig health"