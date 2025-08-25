# Homelab Optimizations Applied

## ✅ All optimizations are now persistent in Git!

## Summary of Changes

### 1. **CoreDNS** - Reduced from 2 to 1 replica
- Saves ~100MB memory and reduces CPU usage
- Single replica is sufficient for a 3-node homelab
- **Persistent in**: `manifests/coredns/values.yaml` and `manifests/coredns/patch-replicas.yaml`

### 2. **Cilium** - Added resource limits
- **Agent pods**: 100m CPU / 100Mi memory (requests), 500m CPU / 500Mi memory (limits)
- **Operator**: 50m CPU / 50Mi memory (requests), 200m CPU / 200Mi memory (limits)
- Prevents Cilium from consuming excessive resources while maintaining network performance
- **Persistent in**: `manifests/cilium/values.talos.yaml`

### 3. **SMB CSI Driver** - Optimized deployment
- **Node pods**: Now only run on worker nodes (not on control plane)
- **Resource limits**: 10m CPU / 20Mi memory (requests), 100m CPU / 100Mi memory (limits) per container
- Reduced from 3 to 2 node pods (only on workers that actually use storage)
- **Persistent in**: `manifests/smb-csi-driver/patches/daemonset-resources.yaml` and `manifests/smb-csi-driver/patches/deployment-resources.yaml`

## Before vs After

**Before**: 11 pods for Cilium + SMB CSI
- 3 Cilium agents + 1 operator
- 3 SMB CSI node + 1 controller
- 2 CoreDNS

**After**: 8 pods total
- 3 Cilium agents + 1 operator (with resource limits)
- 2 SMB CSI node + 1 controller (with resource limits, nodes only on workers)
- 1 CoreDNS

## Resource Savings
- Approximately 200-300MB less memory usage
- Reduced CPU overhead on control plane node
- Better resource allocation for actual workloads

## Configuration Files Created/Modified

1. **CoreDNS**:
   - `manifests/coredns/values.yaml` - Set replicaCount to 1
   - `manifests/coredns/patch-replicas.yaml` - Kustomize patch for replicas

2. **Cilium**:
   - `manifests/cilium/values.talos.yaml` - Added resource limits

3. **SMB CSI Driver**:
   - `manifests/smb-csi-driver/patches/daemonset-resources.yaml` - Resource limits and node selector
   - `manifests/smb-csi-driver/patches/deployment-resources.yaml` - Controller resource limits
   - `manifests/smb-csi-driver/kustomization.yaml` - Added patches

## Rollback Commands (if needed)
```bash
# Restore CoreDNS replicas
kubectl scale deployment coredns -n kube-system --replicas=2

# Remove Cilium resource limits
kubectl patch daemonset cilium -n kube-system --type='json' -p='[{"op": "remove", "path": "/spec/template/spec/containers/0/resources"}]'
kubectl patch deployment cilium-operator -n kube-system --type='json' -p='[{"op": "remove", "path": "/spec/template/spec/containers/0/resources"}]'

# Remove SMB CSI resource limits and node selector
kubectl patch daemonset csi-smb-node -n kube-system --type='json' -p='[{"op": "remove", "path": "/spec/template/spec/nodeSelector/node.kubernetes.io~1type"}]'
```