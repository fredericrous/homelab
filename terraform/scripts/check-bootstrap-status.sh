#!/bin/bash
# Check if Talos cluster is already bootstrapped

CONTROL_PLANE_IP="${1:-192.168.1.67}"
TALOSCONFIG="${2:-./talosconfig}"

# Try to get cluster status
if talosctl --talosconfig="$TALOSCONFIG" -n "$CONTROL_PLANE_IP" cluster show >/dev/null 2>&1; then
    echo "Cluster is already bootstrapped"
    exit 0
else
    echo "Cluster needs bootstrap"
    exit 1
fi