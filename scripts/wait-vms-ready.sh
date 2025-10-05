#!/bin/bash
set -e

# Handle interruption signals to exit cleanly
trap 'echo ""; echo "❌ VM readiness check interrupted by user"; exit 130' INT TERM
trap 'echo "DEBUG: Script failed at line $LINENO"' ERR

echo "🔍 Waiting for VMs to be ready..."

# Check if any arguments were provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <ip1> [ip2] [ip3] ..."
    echo "Example: $0 192.168.1.67 192.168.1.68 192.168.1.69"
    exit 1
fi

# Store all IPs in an array
VM_IPS=("$@")

# Function to check if host responds to ping
check_host() {
    local ip=$1
    ping -c 1 -W 2 "$ip" >/dev/null 2>&1
}

# Function to determine VM type based on position
get_vm_name() {
    local index=$1
    if [ $index -eq 0 ]; then
        echo "CP"  # Control Plane
    else
        echo "W$index"  # Worker
    fi
}

# Wait for all VMs to respond
MAX_RETRIES=60
RETRY_COUNT=0

echo "Monitoring ${#VM_IPS[@]} VMs: ${VM_IPS[*]}"
echo

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    ALL_READY=true
    
    echo -n "Checking VMs: "
    
    # Check each VM
    for i in "${!VM_IPS[@]}"; do
        ip="${VM_IPS[$i]}"
        vm_name=$(get_vm_name $i)
        
        if check_host "$ip"; then
            echo -n "✓ $vm_name($ip) "
        else
            echo -n "✗ $vm_name($ip) "
            ALL_READY=false
        fi
    done
    
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
        echo "Failed VMs:"
        for i in "${!VM_IPS[@]}"; do
            ip="${VM_IPS[$i]}"
            vm_name=$(get_vm_name $i)
            if ! check_host "$ip"; then
                echo "  - $vm_name: $ip"
            fi
        done
        exit 1
    fi
    
    sleep 2
done