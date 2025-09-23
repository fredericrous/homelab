#!/bin/bash
# Script to destroy FluxCD and all deployed resources
# This is the inverse of the bootstrap operation

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper function for colored output
log_info() {
  echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
  echo -e "${YELLOW}⏸️  $1${NC}"
}

log_error() {
  echo -e "${RED}🗑️  $1${NC}"
}

# Check if FluxCD is installed
if ! kubectl get ns flux-system >/dev/null 2>&1; then
  log_info "FluxCD is not installed"
  exit 0
fi

log_error "Removing FluxCD and all resources..."

# First suspend all Flux reconciliations
log_warning "Suspending Flux reconciliation..."

# Suspend all GitRepositories
kubectl get gitrepository -n flux-system -o name 2>/dev/null | xargs -r -I {} kubectl patch {} -n flux-system --type='merge' -p='{"spec":{"suspend":true}}' || true

# Suspend all HelmRepositories
kubectl get helmrepository -n flux-system -o name 2>/dev/null | xargs -r -I {} kubectl patch {} -n flux-system --type='merge' -p='{"spec":{"suspend":true}}' || true

# Suspend all HelmReleases
kubectl get helmrelease -n flux-system -o name 2>/dev/null | xargs -r -I {} kubectl patch {} -n flux-system --type='merge' -p='{"spec":{"suspend":true}}' || true

# Suspend all Kustomizations
kubectl get kustomization -n flux-system -o name 2>/dev/null | xargs -r -I {} kubectl patch {} -n flux-system --type='merge' -p='{"spec":{"suspend":true}}' || true

log_info "Flux reconciliation suspended"

# Wait a moment for reconciliations to stop
log_warning "Waiting for reconciliations to stop..."
sleep 5

# Delete application workloads in reverse dependency order
log_error "Removing application workloads..."

# Remove apps first (don't wait for finalization)
kubectl delete kustomization apps -n flux-system --wait=false --ignore-not-found || true

# Remove infrastructure (don't wait for finalization)
kubectl delete kustomization infrastructure -n flux-system --wait=false --ignore-not-found || true

# Remove infrastructure-core (don't wait for finalization)
kubectl delete kustomization infrastructure-core -n flux-system --wait=false --ignore-not-found || true

# Also delete any other kustomizations (like metallb-config, rook-ceph-cluster)
kubectl delete kustomization -n flux-system --all --wait=false || true

# Special handling for Rook-Ceph cleanup
log_error "Cleaning up Rook-Ceph resources..."
if kubectl get ns rook-ceph >/dev/null 2>&1; then
  # Delete ceph cluster and related resources first
  kubectl delete cephcluster -n rook-ceph --all --wait=false --force --grace-period=0 2>/dev/null || true
  kubectl delete cephblockpool -n rook-ceph --all --wait=false --force --grace-period=0 2>/dev/null || true
  kubectl delete cephfilesystem -n rook-ceph --all --wait=false --force --grace-period=0 2>/dev/null || true
  kubectl delete cephobjectstore -n rook-ceph --all --wait=false --force --grace-period=0 2>/dev/null || true
  
  # Patch all ceph resources to remove finalizers
  for crd in $(kubectl get crd -o name | grep ceph.rook.io); do
    cr_name=$(echo $crd | sed 's/customresourcedefinition.apiextensions.k8s.io\///')
    kubectl get $cr_name -n rook-ceph -o name 2>/dev/null | xargs -r -I {} kubectl patch {} -n rook-ceph -p '{"metadata":{"finalizers":null}}' --type=merge || true
  done
fi

# Delete all resources in all non-system namespaces
log_error "Cleaning up resources in all namespaces..."
for ns in $(kubectl get ns -o name | grep -v -E "(kube-system|kube-public|kube-node-lease|default)" | cut -d/ -f2); do
  echo "  Cleaning namespace $ns..."
  
  # Force delete stuck pods first
  kubectl delete pods -n $ns --all --force --grace-period=0 2>/dev/null || true
  
  # Delete all resources in the namespace dynamically (suppress "No resources found" messages)
  kubectl api-resources --verbs=list --namespaced -o name | xargs -n 1 -I {} sh -c "kubectl delete {} -n $ns --all --wait=false 2>&1 | grep -v 'No resources found' || true"
  
  # Remove finalizers from all resources in the namespace that have them
  # This is a generic approach that will handle any resource with finalizers
  echo "    Removing finalizers from all resources in namespace $ns..."
  
  # Get all resource types that support deletion
  for resource_type in $(kubectl api-resources --verbs=list,delete --namespaced -o name 2>/dev/null); do
    # Get all resources of this type with finalizers
    kubectl get $resource_type -n $ns -o json 2>/dev/null | \
      jq -r '.items[] | select(.metadata.finalizers != null and (.metadata.finalizers | length) > 0) | "\(.kind)/\(.metadata.name)"' | \
      while read resource; do
        echo "      Removing finalizers from $resource"
        kubectl patch $resource -n $ns -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
      done
  done
  
  # Remove finalizers from PVCs
  kubectl get pvc -n $ns -o name 2>/dev/null | xargs -r -I {} kubectl patch {} -n $ns -p '{"metadata":{"finalizers":[]}}' --type=merge || true
done

# Check if flux CLI is available
if command -v flux &> /dev/null; then
  flux uninstall --silent
else
  # Manual cleanup if flux CLI is not available
  echo "Flux CLI not found, performing manual cleanup..."
  
  # Delete all kustomizations first
  kubectl delete kustomization --all -n flux-system --timeout=60s || true
  
  # Delete all helm releases
  kubectl delete helmrelease --all -n flux-system --timeout=60s || true
  
  # Delete flux-system namespace (this will delete all resources in it)
  kubectl delete namespace flux-system --timeout=60s || true
  
  # Delete Flux CRDs
  kubectl get crd -o name | grep fluxcd.io | xargs kubectl delete || true
fi

# Clean up remaining namespaces created by FluxCD
log_error "Cleaning up remaining namespaces..."
# Get all namespaces except core k8s namespaces
for ns in $(kubectl get ns -o name | grep -v -E "(kube-system|kube-public|kube-node-lease|default|flux-system)" | cut -d/ -f2); do
  echo "  Deleting namespace $ns..."
  kubectl delete namespace $ns --wait=false || true
done

# Clean up PersistentVolumes that might be stuck
log_error "Cleaning up stuck PersistentVolumes..."
# Remove finalizers from PVs that are stuck in Released state
kubectl get pv -o json | jq -r '.items[] | select(.status.phase=="Released" or .status.phase=="Terminating") | .metadata.name' | \
  xargs -r -I {} kubectl patch pv {} -p '{"metadata":{"finalizers":[]}}' --type=merge || true

# Force cleanup stuck terminating namespaces
log_error "Force cleaning stuck namespaces..."
for ns in $(kubectl get ns -o json | jq -r '.items[] | select(.status.phase=="Terminating") | .metadata.name'); do
  echo "  Force cleaning namespace $ns..."
  # Remove the kubernetes finalizer
  kubectl patch namespace $ns -p '{"metadata":{"finalizers":[]}}' --type=merge || true
  # If still stuck, use the API directly to remove finalizers
  kubectl get namespace $ns -o json | jq '.metadata.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || true
done

# Clean up any remaining CRDs (excluding core k8s ones)
log_error "Cleaning up CRDs..."
# Get all CRDs that are NOT core Kubernetes CRDs
kubectl get crd -o name | grep -v -E "(k8s.io|kubernetes.io|metrics.k8s.io|apiregistration.k8s.io|admissionregistration.k8s.io)" | xargs -r kubectl delete || true

log_info "FluxCD and all resources removed"
echo "ℹ️  Run 'task bootstrap' to reinstall"