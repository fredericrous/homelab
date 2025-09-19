#!/bin/bash
set -e

# Script to migrate Cilium from VXLAN to native routing
# This should resolve DNS issues caused by tunnel overhead

KUBECONFIG="${1:?Error: KUBECONFIG path required as first argument}"
export KUBECONFIG

echo "🔍 Checking cluster network prerequisites..."

# Check if all nodes are in the same subnet
echo "📊 Node IP addresses:"
nodes=$(kubectl get nodes -o json | jq -r '.items[].status.addresses[] | select(.type=="InternalIP") | .address')
echo "$nodes"

# Extract subnet from first node
first_ip=$(echo "$nodes" | head -1)
subnet_prefix=$(echo "$first_ip" | cut -d. -f1-3)

# Check if all nodes are in same /24
all_same_subnet=true
while IFS= read -r ip; do
  if [[ ! "$ip" =~ ^${subnet_prefix}\. ]]; then
    all_same_subnet=false
    echo "⚠️  Node $ip is in different subnet!"
  fi
done <<< "$nodes"

if [ "$all_same_subnet" = true ]; then
  echo "✅ All nodes are in subnet ${subnet_prefix}.0/24 - native routing supported"
else
  echo "❌ Nodes are in different subnets - native routing may not work"
  echo "   You may need to configure your network infrastructure"
  exit 1
fi

# Check current Cilium mode
echo ""
echo "🔍 Checking current Cilium configuration..."
current_mode=$(kubectl get cm -n kube-system cilium-config -o jsonpath='{.data.routing-mode}' 2>/dev/null || echo "unknown")
tunnel_protocol=$(kubectl get cm -n kube-system cilium-config -o jsonpath='{.data.tunnel-protocol}' 2>/dev/null || echo "unknown")

echo "Current routing mode: $current_mode"
echo "Current tunnel protocol: $tunnel_protocol"

if [ "$current_mode" = "native" ]; then
  echo "✅ Already using native routing!"
  exit 0
fi

# Backup current Cilium values
echo ""
echo "📦 Backing up current Cilium configuration..."
kubectl get cm -n kube-system cilium-config -o yaml > /tmp/cilium-config-backup-$(date +%Y%m%d-%H%M%S).yaml || true
echo "Backup saved to /tmp/"

# Test DNS before migration
echo ""
echo "🧪 Testing DNS before migration..."
dns_test_before=$(kubectl run dns-test-before-$RANDOM --image=busybox:1.28 --rm -it --restart=Never --timeout=10s -- nslookup kubernetes.default.svc.cluster.local 2>&1 || echo "DNS test failed")
if echo "$dns_test_before" | grep -q "Address.*10.96.0.1"; then
  echo "✅ DNS working before migration"
else
  echo "⚠️  DNS already having issues: $dns_test_before"
fi

# Create migration plan
echo ""
echo "📋 Migration Plan:"
echo "1. Update Cilium ConfigMap to use native routing"
echo "2. Restart Cilium pods in a controlled manner"
echo "3. Verify connectivity between pods"
echo "4. Test DNS resolution"
echo "5. Update ArgoCD app to use new values"

echo ""
read -p "Proceed with migration? (yes/no): " -n 3 -r
echo
if [[ ! $REPLY =~ ^[Yy]es$ ]]; then
  echo "Migration cancelled"
  exit 0
fi

# Apply native routing configuration
echo ""
echo "🚀 Applying native routing configuration..."
kubectl patch cm -n kube-system cilium-config --type merge -p '{
  "data": {
    "routing-mode": "native",
    "native-routing-cidr": "10.244.0.0/16",
    "auto-direct-node-routes": "true",
    "enable-endpoint-routes": "true",
    "tunnel": "disabled",
    "enable-bpf-masquerade": "true",
    "enable-host-firewall": "false"
  }
}'

# Remove tunnel-protocol if it exists
kubectl patch cm -n kube-system cilium-config --type json -p='[{"op": "remove", "path": "/data/tunnel-protocol"}]' 2>/dev/null || true

echo "✅ ConfigMap updated"

# Rolling restart of Cilium
echo ""
echo "🔄 Performing rolling restart of Cilium pods..."
kubectl rollout restart ds/cilium -n kube-system

# Wait for rollout to complete
echo "⏳ Waiting for Cilium rollout to complete (this may take a few minutes)..."
kubectl rollout status ds/cilium -n kube-system --timeout=300s

# Give it a bit more time to stabilize
echo "⏳ Waiting for network to stabilize..."
sleep 30

# Verify Cilium status
echo ""
echo "🔍 Checking Cilium status..."
kubectl -n kube-system exec ds/cilium -- cilium status --brief || echo "⚠️  Could not get Cilium status"

# Test connectivity
echo ""
echo "🧪 Testing pod connectivity..."
kubectl run test-client-$RANDOM --image=nginx:alpine --rm -it --restart=Never --timeout=20s -- sh -c "wget -O- http://kubernetes.default.svc.cluster.local:443 2>&1 | head -5" || echo "⚠️  Connectivity test failed"

# Test DNS after migration
echo ""
echo "🧪 Testing DNS after migration..."
dns_test_after=$(kubectl run dns-test-after-$RANDOM --image=busybox:1.28 --rm -it --restart=Never --timeout=10s -- nslookup kubernetes.default.svc.cluster.local 2>&1 || echo "DNS test failed")
if echo "$dns_test_after" | grep -q "Address.*10.96.0.1"; then
  echo "✅ DNS working after migration!"
else
  echo "❌ DNS still having issues: $dns_test_after"
fi

# Check ArgoCD connectivity
echo ""
echo "🔍 Checking ArgoCD components..."
argocd_pods=$(kubectl get pods -n argocd --no-headers | grep -E "repo-server|applicationset" | awk '{print $1}')
for pod in $argocd_pods; do
  echo "Testing DNS from $pod..."
  kubectl exec -n argocd $pod -- sh -c "cat /etc/resolv.conf && echo '---' && getent hosts argocd-repo-server" 2>&1 || echo "Failed to test from $pod"
done

echo ""
echo "📊 Migration Summary:"
echo "- Routing mode changed to: native"
echo "- Tunnel disabled"
echo "- BPF masquerade enabled"
echo "- Direct node routes enabled"

echo ""
echo "📝 Next Steps:"
echo "1. Monitor ArgoCD ApplicationSet controller logs for DNS errors"
echo "2. If DNS issues persist, check MTU settings (currently using auto-detection)"
echo "3. Update the ArgoCD Cilium app to use the new values file"
echo ""
echo "To rollback if needed:"
echo "kubectl apply -f /tmp/cilium-config-backup-*.yaml"
echo "kubectl rollout restart ds/cilium -n kube-system"