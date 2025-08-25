#!/bin/bash

echo "=== Applying Talos Configuration to Actual IPs ==="
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# The actual IPs discovered
declare -A actual_ips
actual_ips[talos-cp-1]="192.168.1.77"
actual_ips[talos-wk-1-gpu]="192.168.1.78" 
actual_ips[talos-wk-2]="192.168.1.79"

echo -e "${YELLOW}Found Talos nodes at:${NC}"
echo "  - Control Plane: 192.168.1.77"
echo "  - Worker 1 (GPU): 192.168.1.78"
echo "  - Worker 2: 192.168.1.79"
echo ""

# Apply configurations
echo -e "${BLUE}Applying Talos configurations...${NC}"
for hostname in talos-cp-1 talos-wk-1-gpu talos-wk-2; do
    ip=${actual_ips[$hostname]}
    echo -e "${YELLOW}Configuring ${hostname} at ${ip}...${NC}"
    
    if talosctl apply-config --insecure --nodes "${ip}" --file "configs/${hostname}.yaml"; then
        echo -e "${GREEN}✓ ${hostname} configured successfully${NC}"
    else
        echo -e "${RED}✗ Failed to configure ${hostname}${NC}"
        exit 1
    fi
done

echo ""
echo -e "${GREEN}Configuration applied!${NC}"
echo -e "${YELLOW}Nodes will reboot and come up with static IPs (67, 68, 69)${NC}"
echo ""
echo "Wait about 2 minutes, then check the nodes at their final IPs:"
echo "  talosctl --nodes 192.168.1.67 version"
echo "  talosctl --nodes 192.168.1.68 version"
echo "  talosctl --nodes 192.168.1.69 version"