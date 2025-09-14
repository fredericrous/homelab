#!/bin/bash
set -e

KUBECONFIG="${1:-$HOME/Developer/Perso/homelab/kubeconfig}"
export KUBECONFIG

echo "🔧 Fixing Cilium environment variables..."

# Load environment variables from .env file
if [ -f "$(dirname "$0")/../../.env" ]; then
  echo "Loading environment variables..."
  set -a
  source "$(dirname "$0")/../../.env"
  set +a
else
  echo "ERROR: .env file not found!"
  exit 1
fi

# Verify required variables
if [ -z "$ARGO_CONTROL_PLANE_IP" ]; then
  echo "ERROR: ARGO_CONTROL_PLANE_IP not set!"
  exit 1
fi

echo "Using control plane IP: $ARGO_CONTROL_PLANE_IP"

# Fix Cilium ConfigMap
echo "📝 Patching Cilium ConfigMap..."
kubectl get cm cilium-config -n kube-system -o yaml | \
  sed "s/\${ARGO_CONTROL_PLANE_IP}/$ARGO_CONTROL_PLANE_IP/g" | \
  kubectl apply -f -

# Fix environment variables in DaemonSet and Deployment by patching the entire manifest
echo "📝 Patching Cilium DaemonSet..."
kubectl get ds cilium -n kube-system -o yaml | \
  sed "s/\${ARGO_CONTROL_PLANE_IP}/$ARGO_CONTROL_PLANE_IP/g" | \
  kubectl apply -f -

echo "📝 Patching Cilium Operator Deployment..."
kubectl get deployment cilium-operator -n kube-system -o yaml | \
  sed "s/\${ARGO_CONTROL_PLANE_IP}/$ARGO_CONTROL_PLANE_IP/g" | \
  kubectl apply -f -

# Restart Cilium components
echo "🔄 Restarting Cilium components..."
kubectl rollout restart daemonset/cilium -n kube-system
kubectl rollout restart deployment/cilium-operator -n kube-system

# Wait for Cilium to be ready
echo "⏳ Waiting for Cilium to be ready..."
kubectl wait --for=condition=ready pod -n kube-system -l k8s-app=cilium --timeout=300s || true

echo "✅ Cilium environment variables fixed!"

# Check Cilium status
echo "📊 Cilium pod status:"
kubectl get pods -n kube-system -l k8s-app=cilium -o wide