#!/bin/bash
# Debug script to check Talos cluster status during bootstrap

set -euo pipefail

echo "🔍 Checking Talos cluster bootstrap status..."
echo "========================================"

# Check if talosconfig exists
if [ ! -f ../talosconfig ]; then
    echo "❌ talosconfig not found. Have you run terraform apply?"
    exit 1
fi

export TALOSCONFIG="../talosconfig"

# Get control plane IP
CP_IP=$(grep -A2 'controlplane:' ../talosconfig | grep 'endpoint:' | awk -F'https://' '{print $2}' | awk -F':' '{print $1}' || echo "192.168.1.67")

echo "📍 Control plane IP: $CP_IP"
echo ""

# Check Talos service status
echo "🔧 Talos Services Status:"
talosctl -n $CP_IP service || echo "Unable to get service status"
echo ""

# Check etcd status
echo "📊 Etcd Status:"
talosctl -n $CP_IP etcd status || echo "Etcd not ready yet"
echo ""

# Check dmesg for errors
echo "📜 Recent Talos logs (errors/warnings):"
talosctl -n $CP_IP dmesg | grep -E "(error|warning|fail)" | tail -20 || echo "No recent errors"
echo ""

# Check kubelet logs specifically
echo "🤖 Kubelet logs:"
talosctl -n $CP_IP logs kubelet | tail -20 || echo "Kubelet not running yet"
echo ""

# If kubeconfig exists, check k8s status
if [ -f ../kubeconfig ]; then
    export KUBECONFIG="../kubeconfig"
    echo ""
    echo "☸️  Kubernetes Status:"
    echo "Nodes:"
    kubectl get nodes -o wide 2>/dev/null || echo "Cannot connect to Kubernetes API"
    echo ""
    echo "Pods in kube-system:"
    kubectl get pods -n kube-system 2>/dev/null || echo "Cannot list pods"
    echo ""
    echo "Cilium status:"
    kubectl -n kube-system get pods -l k8s-app=cilium 2>/dev/null || echo "Cilium not found"
else
    echo "⚠️  kubeconfig not found - cluster may not be bootstrapped yet"
fi

echo ""
echo "💡 Note: 'node not found' errors are NORMAL until Cilium CNI is installed!"
echo "💡 Nodes will remain NotReady until CNI pods are running."