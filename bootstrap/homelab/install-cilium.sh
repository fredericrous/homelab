#!/bin/bash
# Install Cilium CNI (required before workers can join)
# This script installs Cilium using Helm with native routing configuration

set -euo pipefail

# Handle interruption signals to exit cleanly
trap 'echo ""; echo "❌ Cilium installation interrupted by user"; exit 130' INT TERM
# Add debug trap to see where script fails
trap 'echo "DEBUG: Script failed at line $LINENO"' ERR

# Ensure KUBECONFIG is set
if [ -z "${KUBECONFIG:-}" ]; then
  echo "ERROR: KUBECONFIG environment variable must be set"
  exit 1
fi

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
  echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
  echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
  echo -e "${RED}❌ $1${NC}"
}

# Get control plane IP from environment variable or detect it
get_control_plane_ip() {
  if [ -n "${CONTROL_PLANE_IP:-}" ]; then
    echo "$CONTROL_PLANE_IP"
  elif kubectl get nodes -o wide 2>/dev/null | grep -q control-plane; then
    kubectl get nodes -o wide 2>/dev/null | grep control-plane | awk '{print $6}' | head -1
  else
    # Fallback - extract from kubeconfig
    kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null | sed 's|https://||' | sed 's|:.*||'
  fi
}

echo "🌐 Installing Cilium CNI..."

# Add Cilium helm repo
helm repo add cilium https://helm.cilium.io
helm repo update

# Get control plane IP
CONTROL_PLANE_IP=$(get_control_plane_ip)
echo "Using control plane IP: $CONTROL_PLANE_IP"

# Create temporary values file with environment substitution
cat > /tmp/cilium-bootstrap-values.yaml << EOF
# Cilium bootstrap configuration for homelab
routingMode: "native"
ipv4NativeRoutingCIDR: "10.244.0.0/16"
autoDirectNodeRoutes: true
endpointRoutes:
  enabled: true

kubeProxyReplacement: true
k8sServiceHost: "$CONTROL_PLANE_IP"
k8sServicePort: 6443

bandwidthManager:
  enabled: true
  bbr: true

bpf:
  masquerade: true
  tproxy: true
  hostRouting: false

ipam:
  mode: "kubernetes"
  operator:
    clusterPoolIPv4PodCIDRList: ["10.244.0.0/16"]
    clusterPoolIPv4MaskSize: 24

dnsProxy:
  enabled: true
  enableTransparentMode: true
  minTTL: 3600
  maxTTL: 86400

mtu: 1450

hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
  metrics:
    enabled:
      - dns:query
      - drop
      - tcp
      - flow
      - icmp
      - http

operator:
  replicas: 1
  prometheus:
    enabled: true

healthChecking: true
healthPort: 9879

sysctlfix:
  enabled: false

securityContext:
  capabilities:
    ciliumAgent:
      - CHOWN
      - KILL
      - NET_ADMIN
      - NET_RAW
      - IPC_LOCK
      - SYS_ADMIN
      - SYS_RESOURCE
      - DAC_OVERRIDE
      - FOWNER
      - SETGID
      - SETUID
    cleanCiliumState:
      - NET_ADMIN
      - SYS_ADMIN
      - SYS_RESOURCE

prometheus:
  enabled: true
  serviceMonitor:
    enabled: false

socketLB:
  hostNamespaceOnly: true

cni:
  exclusive: false
EOF

# Install Cilium
if helm list -n kube-system | grep -q cilium; then
  log_info "Cilium is already installed"
  # Skip waiting loop if already installed and running
  running_pods=$(kubectl get pods -n kube-system -l k8s-app=cilium --field-selector=status.phase=Running --no-headers 2>/dev/null || true)
  if [ -z "$running_pods" ]; then
    running_count=0
  else
    running_count=$(echo "$running_pods" | wc -l)
    running_count=$(echo "$running_count" | tr -d ' \n\r\t')
  fi
  total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
  total_nodes=$(echo "$total_nodes" | tr -d ' \n\r\t')
  if [ "$running_count" -eq "$total_nodes" ]; then
    log_info "Cilium is already fully deployed ($running_count/$total_nodes pods running)"
    rm -f /tmp/cilium-bootstrap-values.yaml
    log_info "Cilium CNI installed successfully!"
    exit 0
  fi
else
  # Install without --wait to avoid timeout issues
  # We'll handle readiness checking in our own loop below
  helm install cilium cilium/cilium \
    --version 1.18.1 \
    --namespace kube-system \
    --values /tmp/cilium-bootstrap-values.yaml
fi

# Clean up temporary file
rm -f /tmp/cilium-bootstrap-values.yaml

# Give Cilium a moment to initialize
echo "⏳ Waiting for Cilium to initialize..."
sleep 5

echo "⏳ Waiting for Cilium to be ready..."
# Wait for Cilium pods on all ready nodes
ready_count=0

# Get node counts with better error handling
# After helm install, there might be a brief period where API is unstable
echo "Checking cluster nodes..."
for attempt in {1..5}; do
  echo "DEBUG: Checking nodes attempt $attempt"
  if kubectl get nodes >/dev/null 2>&1; then
    echo "DEBUG: kubectl get nodes succeeded"
    break
  fi
  echo "  Waiting for API to stabilize (attempt $attempt/5)..."
  sleep 2
done
echo "DEBUG: After node check loop"

# Now get the actual counts
echo "DEBUG: Getting node output..."
node_output=$(kubectl get nodes --no-headers 2>&1) || true
echo "DEBUG: Got node_output, checking if empty..."
if [[ "$node_output" == *"No resources found"* ]] || [ -z "$node_output" ]; then
  log_warning "No nodes found - this is normal right after Cilium installation with kubeProxyReplacement"
  log_warning "Waiting for nodes to reappear..."

  # Give it more time and retry
  for wait_attempt in {1..10}; do
    sleep 3
    node_output=$(kubectl get nodes --no-headers 2>&1) || true
    if [[ "$node_output" != *"No resources found"* ]] && [ -n "$node_output" ]; then
      log_info "Nodes are back online"
      break
    fi
    echo "  Still waiting for nodes (attempt $wait_attempt/10)..."
  done

  # Final check
  if [[ "$node_output" == *"No resources found"* ]] || [ -z "$node_output" ]; then
    log_error "No nodes found after waiting - cluster may have issues"
    echo "Node output: $node_output"
    exit 1
  fi
fi

# Handle empty output correctly - wc -l returns 1 for empty string
if [ -z "$node_output" ]; then
  total_nodes=0
  ready_nodes=0
else
  # Clean total_nodes count
  total_nodes=$(echo "$node_output" | wc -l)
  total_nodes=$(echo "$total_nodes" | tr -d ' \n\r\t')
  
  # grep returns exit code 1 if no matches found, use || true to prevent script exit
  ready_lines=$(echo "$node_output" | grep -w Ready 2>/dev/null || true)
  if [ -z "$ready_lines" ]; then
    ready_nodes=0
  else
    ready_nodes=$(echo "$ready_lines" | wc -l)
    ready_nodes=$(echo "$ready_nodes" | tr -d ' \n\r\t')
  fi
fi

# Debug output
echo "DEBUG: total_nodes=$total_nodes, ready_nodes=$ready_nodes"
echo "DEBUG: node_output:"
echo "$node_output"

# Validate we have nodes
if [ "$total_nodes" -eq 0 ]; then
  log_error "No nodes found in cluster"
  exit 1
fi

for i in {1..30}; do
  echo "DEBUG: Starting loop iteration $i"

  # Get current node status each iteration (it changes after CNI installation)
  node_output=$(kubectl get nodes --no-headers 2>&1) || true
  if [[ "$node_output" == *"No resources found"* ]] || [ -z "$node_output" ]; then
    total_nodes=0
    ready_nodes=0
  else
    total_nodes=$(echo "$node_output" | wc -l)
    total_nodes=$(echo "$total_nodes" | tr -d ' \n\r\t')
    
    ready_lines=$(echo "$node_output" | grep -w Ready 2>/dev/null || true)
    if [ -z "$ready_lines" ]; then
      ready_nodes=0
    else
      ready_nodes=$(echo "$ready_lines" | wc -l)
      ready_nodes=$(echo "$ready_nodes" | tr -d ' \n\r\t')
    fi
  fi

  # Get running pods count, handle empty results gracefully
  ready_pods=$(kubectl get pods -n kube-system -l k8s-app=cilium --field-selector=status.phase=Running --no-headers 2>/dev/null || true)
  if [ -z "$ready_pods" ]; then
    ready_count=0
  else
    ready_count=$(echo "$ready_pods" | wc -l)
    ready_count=$(echo "$ready_count" | tr -d ' \n\r\t')
  fi
  
  pending_pods=$(kubectl get pods -n kube-system -l k8s-app=cilium --field-selector=status.phase=Pending --no-headers 2>/dev/null || true)
  if [ -z "$pending_pods" ]; then
    pending_count=0
  else
    pending_count=$(echo "$pending_pods" | wc -l)
    pending_count=$(echo "$pending_count" | tr -d ' \n\r\t')
  fi

  echo "  Cilium pods ready: $ready_count/$total_nodes (Running: $ready_count, Pending: $pending_count, attempt $i/30)"
  echo "  Node status: $ready_nodes/$total_nodes Ready"

  # Primary success condition: All nodes are Ready AND have Cilium pods
  if [ "$ready_nodes" -eq "$total_nodes" ] && [ "$ready_count" -ge "$ready_nodes" ] && [ "$total_nodes" -gt 0 ]; then
    log_info "Cilium CNI installation complete: $ready_nodes Ready nodes with $ready_count running pods"
    break
  # Secondary success: Cilium pods match ready nodes (partial deployment acceptable)  
  elif [ "$ready_nodes" -gt 0 ] && [ "$ready_count" -eq "$ready_nodes" ] && [ "$pending_count" -eq 0 ]; then
    log_warning "Cilium is running on all Ready nodes ($ready_count/$ready_nodes)"
    if [ "$ready_nodes" -lt "$total_nodes" ]; then
      log_warning "$(($total_nodes - $ready_nodes)) node(s) are NotReady - will get Cilium when they become Ready"
      kubectl get nodes | grep NotReady || true
    fi
    break
  # Still waiting for nodes to become Ready after CNI installation
  elif [ "$total_nodes" -gt 0 ] && [ "$ready_nodes" -eq 0 ]; then
    echo "  All $total_nodes nodes are NotReady, waiting for them to become Ready after CNI installation..."
  # Still waiting for Cilium pods to start
  elif [ "$ready_nodes" -gt 0 ] && [ "$ready_count" -lt "$ready_nodes" ]; then
    echo "  Waiting for Cilium pods to start on Ready nodes ($ready_count/$ready_nodes running)..."
  fi

  sleep 10
done

echo "DEBUG: After loop - ready_count=$ready_count, ready_nodes=$ready_nodes"

# Get final node status for validation
final_node_output=$(kubectl get nodes --no-headers 2>&1) || true
if [[ "$final_node_output" == *"No resources found"* ]] || [ -z "$final_node_output" ]; then
  final_ready_nodes=0
else
  ready_lines=$(echo "$final_node_output" | grep -w Ready 2>/dev/null || true)
  if [ -z "$ready_lines" ]; then
    final_ready_nodes=0
  else
    final_ready_nodes=$(echo "$ready_lines" | wc -l)
    final_ready_nodes=$(echo "$final_ready_nodes" | tr -d ' \n\r\t')
  fi
fi

# Final validation - ensure we have Cilium on ready nodes
if [ "$final_ready_nodes" -gt 0 ] && [ "$ready_count" -lt "$final_ready_nodes" ]; then
  log_error "Cilium deployment incomplete: only $ready_count/$final_ready_nodes pods on Ready nodes"
  log_error "This indicates a Cilium configuration or resource issue"
  exit 1
fi

# Basic validation - nodes should be ready after CNI installation
log_info "Validating cluster readiness..."
ready_worker_lines=$(kubectl get nodes --no-headers | grep -v control-plane | grep -w Ready 2>/dev/null || true)
if [ -z "$ready_worker_lines" ]; then
  ready_workers=0
else
  ready_workers=$(echo "$ready_worker_lines" | wc -l)
  ready_workers=$(echo "$ready_workers" | tr -d ' \n\r\t')
fi
if [ "$ready_workers" -gt 0 ]; then
  log_info "✅ $ready_workers worker node(s) are ready"
else
  log_warning "⚠️  No worker nodes are ready yet"
fi

log_info "Cilium CNI installed successfully!"
echo ""
echo "CNI Status:"
kubectl get pods -n kube-system -l k8s-app=cilium
echo ""
echo "Node Status:"
kubectl get nodes
