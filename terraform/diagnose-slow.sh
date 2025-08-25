#!/bin/bash

echo "=== Terraform Performance Diagnostic ==="
echo ""

# 1. Check VM states in Proxmox
echo "1. Checking VM states in Proxmox..."
for vmid in 100 101 102; do
    echo -n "VM $vmid: "
    curl -sk -X GET \
        "https://192.168.1.66:8006/api2/json/nodes/proxmox/qemu/${vmid}/status/current" \
        -H "Authorization: PVEAuthCookie=$(curl -sk -X POST "https://192.168.1.66:8006/api2/json/access/ticket" \
            -d "username=root@pam&password=Do what I do. Hold tight and pretend it's a plan!" | jq -r '.data.ticket')" | \
        jq -r '.data.status' 2>/dev/null || echo "Error getting status"
done
echo ""

# 2. Test with targeted refresh
echo "2. Testing targeted refresh times..."
echo "Control plane (no GPU):"
time terraform plan -target='module.vms["controlplane"]' -refresh=true >/dev/null 2>&1
echo ""

echo "Worker 2 (no GPU):"
time terraform plan -target='module.vms["worker2"]' -refresh=true >/dev/null 2>&1
echo ""

echo "Worker 1 (with GPU):"
time terraform plan -target='module.vms["worker1"]' -refresh=true >/dev/null 2>&1
echo ""

# 3. Test without refresh
echo "3. Testing without refresh..."
time terraform plan -refresh=false >/dev/null 2>&1
echo ""

# 4. Enable debug logs for detailed timing
echo "4. To get detailed timing, run:"
echo "TF_LOG=DEBUG terraform plan 2>&1 | grep -E '(proxmox|refresh|GET|POST)' | head -20"