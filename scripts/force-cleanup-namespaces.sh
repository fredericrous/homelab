#!/bin/bash
# Force cleanup stuck namespaces - use when destroy-flux.sh doesn't fully clean up
set -euo pipefail
trap 'echo "DEBUG: Script failed at line $LINENO"' ERR

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
  echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
  echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
  echo -e "${RED}🔧 $1${NC}"
}

log_error "Starting aggressive namespace cleanup..."

# Function to force delete a namespace
force_delete_namespace() {
  local ns=$1
  echo "Force deleting namespace: $ns"
  
  # Step 1: Delete all resources in the namespace
  log_warning "Deleting all resources in $ns..."
  kubectl api-resources --verbs=list --namespaced -o name | while read resource; do
    kubectl delete $resource --all -n $ns --force --grace-period=0 2>/dev/null || true
  done
  
  # Step 2: Patch all resources to remove finalizers
  log_warning "Removing finalizers from all resources in $ns..."
  kubectl api-resources --verbs=list --namespaced -o name | while read resource; do
    kubectl get $resource -n $ns -o name 2>/dev/null | while read item; do
      kubectl patch $item -n $ns --type='json' -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
    done
  done
  
  # Step 3: Remove namespace finalizers
  log_warning "Removing namespace finalizers..."
  kubectl patch namespace $ns -p '{"metadata":{"finalizers":null}}' --type=merge || true
  
  # Step 4: Force finalize via API
  log_warning "Force finalizing namespace via API..."
  kubectl get namespace $ns -o json | \
    jq '.spec = {} | .status = {} | .metadata.finalizers = []' | \
    kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || true
}

# Get all terminating namespaces
TERMINATING_NS=$(kubectl get ns -o json | jq -r '.items[] | select(.status.phase=="Terminating") | .metadata.name')

if [ -z "$TERMINATING_NS" ]; then
  log_info "No terminating namespaces found"
else
  for ns in $TERMINATING_NS; do
    force_delete_namespace $ns
  done
fi

# Special handling for flux-system
if kubectl get ns flux-system >/dev/null 2>&1; then
  log_error "flux-system namespace found, forcing deletion..."
  force_delete_namespace flux-system
fi

# Final verification
sleep 2
log_info "Checking final namespace status..."
kubectl get ns

REMAINING_TERMINATING=$(kubectl get ns -o json | jq -r '.items[] | select(.status.phase=="Terminating") | .metadata.name' | wc -l)
if [ "$REMAINING_TERMINATING" -gt 0 ]; then
  log_warning "Still have $REMAINING_TERMINATING terminating namespaces"
  log_warning "You may need to restart the kube-apiserver or check for webhook issues"
else
  log_info "All namespaces cleaned up successfully!"
fi