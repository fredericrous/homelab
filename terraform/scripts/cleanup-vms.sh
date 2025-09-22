#!/bin/bash
set -e

# Script to clean up existing VMs from Proxmox before fresh deployment
# Reads configuration from terraform.tfvars

echo "=== Proxmox VM Cleanup Script ==="
echo "This will remove VMs defined in terraform.tfvars"
echo

# Check if terraform.tfvars exists
if [ ! -f "terraform.tfvars" ]; then
    echo "ERROR: terraform.tfvars not found. Run this script from the terraform directory."
    exit 1
fi

# Extract Proxmox credentials from terraform.tfvars
PROXMOX_API=$(grep "proxmox_api_url" terraform.tfvars | cut -d'"' -f2)
PROXMOX_USER=$(grep "proxmox_user" terraform.tfvars | cut -d'"' -f2)
PROXMOX_PASS=$(grep "proxmox_password" terraform.tfvars | cut -d'"' -f2)
PROXMOX_NODE=$(grep "proxmox_node" terraform.tfvars | cut -d'"' -f2)

if [ -z "$PROXMOX_API" ] || [ -z "$PROXMOX_USER" ] || [ -z "$PROXMOX_PASS" ] || [ -z "$PROXMOX_NODE" ]; then
    echo "ERROR: Could not extract Proxmox credentials from terraform.tfvars"
    exit 1
fi

echo "Connecting to Proxmox API at $PROXMOX_API..."

# Get API token
AUTH_RESPONSE=$(curl -s -k -d "username=$PROXMOX_USER&password=$PROXMOX_PASS" \
    "$PROXMOX_API/access/ticket")

TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.data.ticket')
CSRF=$(echo "$AUTH_RESPONSE" | jq -r '.data.CSRFPreventionToken')

if [ "$TOKEN" == "null" ] || [ -z "$TOKEN" ]; then
    echo "ERROR: Failed to authenticate with Proxmox API"
    echo "Response: $AUTH_RESPONSE"
    exit 1
fi

echo "Authentication successful"
echo

# Function to stop and remove a VM
remove_vm() {
    local vm_id=$1
    local vm_type=$2
    
    echo "Checking $vm_type VM $vm_id..."
    
    # Check if VM exists
    VM_STATUS=$(curl -s -k "$PROXMOX_API/nodes/$PROXMOX_NODE/qemu/$vm_id/status/current" \
        -H "Cookie: PVEAuthCookie=$TOKEN" \
        -H "CSRFPreventionToken: $CSRF")
    
    if echo "$VM_STATUS" | grep -q "does not exist"; then
        echo "  VM $vm_id does not exist, skipping..."
        return
    fi
    
    # Stop VM if running
    echo "  Stopping VM $vm_id..."
    STOP_RESPONSE=$(curl -s -k -X POST "$PROXMOX_API/nodes/$PROXMOX_NODE/qemu/$vm_id/status/stop" \
        -H "Cookie: PVEAuthCookie=$TOKEN" \
        -H "CSRFPreventionToken: $CSRF")
    
    # Wait for VM to stop
    sleep 3
    
    # Remove VM
    echo "  Removing VM $vm_id..."
    DELETE_RESPONSE=$(curl -s -k -X DELETE "$PROXMOX_API/nodes/$PROXMOX_NODE/qemu/$vm_id" \
        -H "Cookie: PVEAuthCookie=$TOKEN" \
        -H "CSRFPreventionToken: $CSRF")
    
    if echo "$DELETE_RESPONSE" | grep -q "UPID"; then
        echo "  VM $vm_id removal initiated successfully"
    else
        echo "  Warning: VM $vm_id removal may have failed: $DELETE_RESPONSE"
    fi
}

# Extract control plane VM ID from terraform.tfvars
CONTROL_VMID=$(grep -A5 "controlplane = {" terraform.tfvars | grep "vmid" | grep -o '[0-9]\+' || echo "100")
echo "Control Plane VM ID: $CONTROL_VMID"

# Remove Control Plane VM
remove_vm "$CONTROL_VMID" "Control Plane"

# Extract and remove worker VMs from terraform.tfvars
echo
echo "Extracting worker VM IDs from terraform.tfvars..."
WORKER_VMIDS=$(grep -A50 "workers = \[" terraform.tfvars | grep -B50 "\]" | grep "vmid" | grep -o '[0-9]\+' || echo "")

if [ -n "$WORKER_VMIDS" ]; then
    for vm_id in $WORKER_VMIDS; do
        remove_vm "$vm_id" "Worker"
    done
else
    echo "No worker VMs found in terraform.tfvars"
fi

echo
echo "=== Cleanup complete ==="
echo "You can now run 'terraform apply' to create fresh VMs"