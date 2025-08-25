#!/bin/bash

echo "=== VM Network Status Check ==="
echo ""

# Get Proxmox credentials
PROXMOX_HOST="192.168.1.66"
PROXMOX_USER="root@pam"
PROXMOX_PASS="Do what I do. Hold tight and pretend it's a plan!"

# Get auth ticket
TICKET=$(curl -sk -X POST "https://${PROXMOX_HOST}:8006/api2/json/access/ticket" \
    -d "username=${PROXMOX_USER}&password=${PROXMOX_PASS}" | jq -r '.data.ticket')

echo "1. Checking VM Status and Network Configuration:"
echo ""

for vmid in 100 101 102; do
    case $vmid in
        100) name="talos-cp-1" ;;
        101) name="talos-wk-1-gpu" ;;
        102) name="talos-wk-2" ;;
    esac
    
    echo "VM $vmid ($name):"
    
    # Get VM status
    status=$(curl -sk -X GET \
        "https://${PROXMOX_HOST}:8006/api2/json/nodes/proxmox/qemu/${vmid}/status/current" \
        -H "Authorization: PVEAuthCookie=${TICKET}" | jq -r '.data.status')
    echo "  Status: $status"
    
    # Get network config
    config=$(curl -sk -X GET \
        "https://${PROXMOX_HOST}:8006/api2/json/nodes/proxmox/qemu/${vmid}/config" \
        -H "Authorization: PVEAuthCookie=${TICKET}")
    
    mac=$(echo "$config" | jq -r '.data.net0' | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' || echo "Not found")
    echo "  MAC Address: $mac"
    
    # Try to get agent info if available
    agent_info=$(curl -sk -X GET \
        "https://${PROXMOX_HOST}:8006/api2/json/nodes/proxmox/qemu/${vmid}/agent/network-get-interfaces" \
        -H "Authorization: PVEAuthCookie=${TICKET}" 2>/dev/null)
    
    if echo "$agent_info" | grep -q "result"; then
        ip=$(echo "$agent_info" | jq -r '.data.result[] | select(.name=="eth0") | .["ip-addresses"][] | select(.["ip-address-type"]=="ipv4") | .["ip-address"]' 2>/dev/null || echo "No IP")
        echo "  Current IP: $ip"
    else
        echo "  Current IP: Guest agent not running"
    fi
    
    echo ""
done

echo "2. Checking DHCP Leases on Router/DHCP Server:"
echo "   You need to check your router/DHCP server for these MAC addresses:"
echo "   - BC:24:11:00:00:67 should get 192.168.1.67"
echo "   - BC:24:11:00:00:68 should get 192.168.1.68"
echo "   - BC:24:11:00:00:69 should get 192.168.1.69"
echo ""

echo "3. Scanning network for Talos nodes:"
echo "   Looking for nodes responding on port 50000 (Talos API)..."
for i in {60..80}; do
    if timeout 1 nc -zv 192.168.1.$i 50000 >/dev/null 2>&1; then
        echo "   Found Talos node at 192.168.1.$i"
    fi
done

echo ""
echo "4. Checking ARP table for MAC addresses:"
arp -a | grep -E "(BC:24:11:00:00:67|BC:24:11:00:00:68|BC:24:11:00:00:69)" || echo "   No matching MACs found in ARP table"