#!/bin/bash
# Script to wipe Ceph data from all disks
# This should be run when you need to completely clean Ceph storage

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
  echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
  echo -e "${RED}❌ $1${NC}"
}

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
  log_error "kubectl is required but not installed"
  exit 1
fi

# Check if cluster is accessible
if ! kubectl get nodes >/dev/null 2>&1; then
  log_error "Cannot access Kubernetes cluster"
  exit 1
fi


# Check if rook-ceph namespace exists and is not terminating
NAMESPACE_STATUS=$(kubectl get ns rook-ceph -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

if [ "$NAMESPACE_STATUS" = "Terminating" ]; then
  log_warning "rook-ceph namespace is terminating, using kube-system namespace instead"
  CLEANUP_NAMESPACE="kube-system"
elif [ "$NAMESPACE_STATUS" = "NotFound" ]; then
  log_info "Creating rook-ceph namespace..."
  kubectl create namespace rook-ceph
  CLEANUP_NAMESPACE="rook-ceph"
else
  CLEANUP_NAMESPACE="rook-ceph"
fi

# Create the cleanup job
log_warning "Creating disk cleanup job in namespace: $CLEANUP_NAMESPACE"
cat <<'EOF' | sed "s/CLEANUP_NAMESPACE/$CLEANUP_NAMESPACE/g" | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ceph-disk-cleanup
  namespace: CLEANUP_NAMESPACE
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ceph-disk-cleanup
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ceph-disk-cleanup
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ceph-disk-cleanup
subjects:
- kind: ServiceAccount
  name: ceph-disk-cleanup
  namespace: CLEANUP_NAMESPACE
---
apiVersion: batch/v1
kind: Job
metadata:
  name: wipe-ceph-disks
  namespace: CLEANUP_NAMESPACE
spec:
  parallelism: 10
  template:
    spec:
      restartPolicy: Never
      hostNetwork: true
      hostPID: true
      hostIPC: true
      serviceAccountName: ceph-disk-cleanup
      containers:
      - name: disk-wipe
        image: rook/ceph:v1.15.5
        command: ["/bin/bash", "-c"]
        args:
        - |
          set -x
          
          echo "Starting Ceph disk cleanup on node $(hostname)"
          
          # Clean up Ceph data directories
          echo "Removing Rook data directories..."
          rm -rf /var/lib/rook/*
          
          # Find all disks
          echo "Scanning for disks to wipe..."
          for disk in $(lsblk -ndo NAME,TYPE | grep disk | awk '{print "/dev/"$1}'); do
            # Skip the OS disk (sda)
            if [ "$disk" = "/dev/sda" ]; then
              echo "Skipping OS disk $disk"
              continue
            fi
            
            if [ -e "$disk" ]; then
              echo "Wiping disk: $disk"
              
              # Always wipe non-OS disks (force wipe)
              # Wipe the beginning of the disk (1GB to be sure)
              dd if=/dev/zero of="$disk" bs=1M count=1024 status=progress || true
              
              # Remove partition table
              sgdisk --zap-all "$disk" || true
              
              # Wipe the end of the disk too (GPT backup)
              dd if=/dev/zero of="$disk" bs=1M count=100 seek=$(($(blockdev --getsz "$disk")/2048 - 100)) status=progress || true
              
              # Final wipe of partition table
              dd if=/dev/zero of="$disk" bs=512 count=34 status=progress || true
              dd if=/dev/zero of="$disk" bs=512 count=34 seek=$(($(blockdev --getsz "$disk") - 34)) status=progress || true
              
              # Inform kernel of partition changes
              partprobe "$disk" || true
              
              echo "Disk $disk wiped successfully"
            fi
          done
          
          # Remove any LVM volumes created by Ceph
          echo "Checking for Ceph LVM volumes..."
          for vg in $(vgs --noheadings -o vg_name | grep ceph); do
            echo "Removing volume group: $vg"
            vgremove -f "$vg" 2>/dev/null || true
          done
          
          # Clean up any remaining device mapper entries
          for dm in $(dmsetup ls | grep ceph | awk '{print $1}'); do
            echo "Removing device mapper entry: $dm"
            dmsetup remove "$dm" 2>/dev/null || true
          done
          
          echo "Ceph disk cleanup completed on node $(hostname)"
        securityContext:
          privileged: true
          runAsUser: 0
          runAsGroup: 0
        volumeMounts:
        - name: dev
          mountPath: /dev
        - name: var-lib-rook
          mountPath: /var/lib/rook
        - name: sys
          mountPath: /sys
      volumes:
      - name: dev
        hostPath:
          path: /dev
      - name: var-lib-rook
        hostPath:
          path: /var/lib/rook
      - name: sys
        hostPath:
          path: /sys
      tolerations:
      - operator: Exists
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                job-name: wipe-ceph-disks
            topologyKey: kubernetes.io/hostname
EOF

# Wait for the job to complete
log_info "Waiting for disk cleanup to complete (timeout: 5 minutes)..."
if kubectl wait --for=condition=complete --timeout=300s job/wipe-ceph-disks -n $CLEANUP_NAMESPACE; then
  log_info "Disk cleanup completed successfully!"
  
  # Show job logs
  echo ""
  log_info "Cleanup logs:"
  kubectl logs -n $CLEANUP_NAMESPACE job/wipe-ceph-disks --tail=50
else
  log_error "Disk cleanup timed out or failed"
  
  # Show job status
  kubectl describe job/wipe-ceph-disks -n $CLEANUP_NAMESPACE
  
  # Show pod logs if available
  echo ""
  log_error "Pod logs:"
  kubectl logs -n $CLEANUP_NAMESPACE -l job-name=wipe-ceph-disks --tail=50
fi

# Clean up
log_info "Cleaning up resources..."
kubectl delete job wipe-ceph-disks -n $CLEANUP_NAMESPACE --ignore-not-found || true
kubectl delete clusterrolebinding ceph-disk-cleanup --ignore-not-found || true
kubectl delete clusterrole ceph-disk-cleanup --ignore-not-found || true
kubectl delete serviceaccount ceph-disk-cleanup -n $CLEANUP_NAMESPACE --ignore-not-found || true

# Only delete namespace if we created it and it's empty
if [ "$CLEANUP_NAMESPACE" = "rook-ceph" ] && [ -z "$(kubectl get all -n rook-ceph -o name 2>/dev/null)" ]; then
  kubectl delete namespace rook-ceph --ignore-not-found || true
fi

log_info "Done!"