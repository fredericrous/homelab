#!/bin/bash
# Script to clean up existing VMs from Proxmox before fresh deployment
# Reads configuration from terraform.tfvars
# Note: Script continues on errors since VMs might already be deleted

trap 'echo "DEBUG: Script failed at line $LINENO"' ERR

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
echo "Looking for Control Plane VM..."
CONTROL_VMID=$(grep -A5 "controlplane = {" terraform.tfvars 2>/dev/null | grep "vmid" 2>/dev/null | grep -o '[0-9]\+' 2>/dev/null | head -n1 || echo "")

if [ -n "$CONTROL_VMID" ]; then
    echo "Control Plane VM ID: $CONTROL_VMID"
    remove_vm "$CONTROL_VMID" "Control Plane"
else
    echo "No Control Plane VM ID found in terraform.tfvars (might already be removed)"
fi

# Extract and remove worker VMs from terraform.tfvars
echo
echo "Looking for Worker VMs..."
WORKER_VMIDS=$(grep -A50 "workers = \[" terraform.tfvars 2>/dev/null | grep -B50 "\]" 2>/dev/null | grep "vmid" 2>/dev/null | grep -o '[0-9]\+' 2>/dev/null || echo "")

if [ -n "$WORKER_VMIDS" ]; then
    echo "Found Worker VMs: $WORKER_VMIDS"
    for vm_id in $WORKER_VMIDS; do
        remove_vm "$vm_id" "Worker"
    done
else
    echo "No Worker VMs found in terraform.tfvars (might already be removed)"
fi

echo
echo "=== Cleanup complete ==="
echo "You can now run 'terraform apply' to create fresh VMs"

# Always exit successfully since VMs might already be removed
exit 0