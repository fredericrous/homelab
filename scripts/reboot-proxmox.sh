#!/bin/bash
set -e
trap 'echo "DEBUG: Script failed at line $LINENO"' ERR

# Script to reboot Proxmox host
# This is often needed after destroying VMs with GPU passthrough

echo "=== Proxmox Host Reboot Script ==="
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

# Initiate reboot
echo "Initiating reboot of Proxmox node $PROXMOX_NODE..."

# Use curl with a short timeout since the host will disconnect during reboot
# We don't expect a response, just fire the command
curl -s -k -X POST "$PROXMOX_API/nodes/$PROXMOX_NODE/status" \
    -H "Cookie: PVEAuthCookie=$TOKEN" \
    -H "CSRFPreventionToken: $CSRF" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "command=reboot" \
    --max-time 2 || true

# Since the reboot disconnects us immediately, we can't check the response
# Just assume it worked if we got this far
echo "✅ Reboot command sent!"
echo
echo "The Proxmox host is rebooting..."
echo "Please wait approximately 2-3 minutes for the host to come back online."
echo
echo "You can check if the host is back by:"
PROXMOX_IP=$(echo "$PROXMOX_API" | sed 's|https://||' | cut -d':' -f1)
echo "  - Pinging: ping $PROXMOX_IP"
echo "  - Opening: $PROXMOX_API"
echo
echo "Waiting for host to go down..."

# Wait for the host to actually shut down (can take 10-30 seconds)
MAX_WAIT=30
WAIT_COUNT=0

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if ! ping -c 1 -W 2 "$PROXMOX_IP" >/dev/null 2>&1; then
        echo "✅ Host is down. Reboot in progress..."
        echo
        echo "The host will take 2-3 minutes to come back online."
        exit 0
    fi
    
    echo -n "."
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

echo
echo "⚠️  Warning: Host is still responding after ${MAX_WAIT} seconds."
echo "The reboot might have failed or is taking longer than expected."
echo "You may need to check the Proxmox console or reboot manually."

