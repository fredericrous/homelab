#!/bin/bash
# Script to apply Harbor CA certificate patch to existing Talos nodes

set -e

echo "Applying Harbor CA certificate patch to Talos nodes..."

# Get the node IPs
CONTROL_PLANE_IP="192.168.1.100"
WORKER_IPS=("192.168.1.101" "192.168.1.102")

# Apply patch to control plane
echo "Applying patch to control plane node: $CONTROL_PLANE_IP"
talosctl patch machineconfig \
  --talosconfig ./talosconfig \
  --nodes $CONTROL_PLANE_IP \
  --patch-file ./patch/harbor-secure-registry.yaml

# Apply patch to worker nodes
for WORKER_IP in "${WORKER_IPS[@]}"; do
  echo "Applying patch to worker node: $WORKER_IP"
  talosctl patch machineconfig \
    --talosconfig ./talosconfig \
    --nodes $WORKER_IP \
    --patch-file ./patch/harbor-secure-registry.yaml
done

echo "Patches applied. Nodes will restart containerd to apply the new configuration."
echo "You can check the status with: talosctl -n <node-ip> service containerd status"