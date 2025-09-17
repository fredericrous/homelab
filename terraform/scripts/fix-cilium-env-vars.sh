#!/bin/bash
set -e

KUBECONFIG="${1:-$HOME/Developer/Perso/homelab/kubeconfig}"
export KUBECONFIG

echo "🔧 Fixing Cilium environment variables..."

# Load control plane IP from global-config.yaml
GLOBAL_CONFIG="$(dirname "$0")/../../manifests/argocd/root/global-config.yaml"
if [ ! -f "$GLOBAL_CONFIG" ]; then
  echo "ERROR: global-config.yaml not found!"
  exit 1
fi

CONTROL_PLANE_IP=$(yq '.controlPlaneIP' "$GLOBAL_CONFIG")

# Verify the control plane IP is loaded
if [ -z "$CONTROL_PLANE_IP" ]; then
  echo "ERROR: Control plane IP not found in global-config.yaml!"
  exit 1
fi

echo "Using control plane IP: $CONTROL_PLANE_IP"

# Fix Cilium ConfigMap
echo "📝 Patching Cilium ConfigMap..."
kubectl get cm cilium-config -n kube-system -o yaml | \
  sed "s/\${ARGO_CONTROL_PLANE_IP}/$CONTROL_PLANE_IP/g" | \
  kubectl apply -f -

# Fix environment variables in DaemonSet and Deployment by patching the entire manifest
echo "📝 Patching Cilium DaemonSet..."
kubectl get ds cilium -n kube-system -o yaml | \
  sed "s/\${ARGO_CONTROL_PLANE_IP}/$CONTROL_PLANE_IP/g" | \
  kubectl apply -f -

echo "📝 Patching Cilium Operator Deployment..."
kubectl get deployment cilium-operator -n kube-system -o yaml | \
  sed "s/\${ARGO_CONTROL_PLANE_IP}/$CONTROL_PLANE_IP/g" | \
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