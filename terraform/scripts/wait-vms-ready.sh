#!/bin/bash
set -e

echo "🔍 Waiting for VMs to be ready..."

# Load IPs from terraform vars
CONTROL_PLANE_IP="${1:-192.168.1.67}"
WORKER1_IP="${2:-192.168.1.68}"
WORKER2_IP="${3:-192.168.1.69}"

# Function to check if host responds to ping
check_host() {
    local ip=$1
    local name=$2
    ping -c 1 -W 2 "$ip" >/dev/null 2>&1
}

# Wait for all VMs to respond
MAX_RETRIES=60
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    ALL_READY=true
    
    echo -n "Checking VMs: "
    
    # Check control plane
    if check_host "$CONTROL_PLANE_IP" "control-plane"; then
        echo -n "✓ CP($CONTROL_PLANE_IP) "
    else
        echo -n "✗ CP($CONTROL_PLANE_IP) "
        ALL_READY=false
    fi
    
    # Check worker 1
    if check_host "$WORKER1_IP" "worker-1"; then
        echo -n "✓ W1($WORKER1_IP) "
    else
        echo -n "✗ W1($WORKER1_IP) "
        ALL_READY=false
    fi
    
    # Check worker 2
    if check_host "$WORKER2_IP" "worker-2"; then
        echo -n "✓ W2($WORKER2_IP) "
    else
        echo -n "✗ W2($WORKER2_IP) "
        ALL_READY=false
    fi
    
    echo "" # newline
    
    if [ "$ALL_READY" = true ]; then
        echo "✅ All VMs are responding to ping!"
        
        # Give them a few more seconds to fully boot
        echo "⏳ Waiting 5 more seconds for Talos API to be ready..."
        sleep 5
        exit 0
    fi
    
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        echo "❌ Timeout waiting for VMs to be ready"
        exit 1
    fi
    
    sleep 2
done