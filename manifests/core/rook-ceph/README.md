# Rook Ceph Storage

Minimal Rook Ceph configuration for homelab cluster.

## Components

- **Rook Operator**: v1.15.8 with device discovery enabled
- **Ceph Cluster**: v18.2.4 (Reef)
- **Storage Devices**: 
  - worker-1-gpu: /dev/sdb (859 GB)
  - worker-2: /dev/sdb (687 GB)
- **Replication**: 2x for data redundancy
- **Storage Classes**:
  - `rook-ceph-block` (default): Block storage for persistent volumes
  - `rook-cephfs`: Shared filesystem for ReadWriteMany access

## Files

- `kustomization.yaml`: Main Kustomize configuration
- `cluster-minimal.yaml`: All cluster resources in one file
- `operator-patch.yaml`: Enable device discovery daemon

## Deployment

```bash
kubectl apply -k .
```

## Cleanup (if needed)

```bash
# Remove old separate files
rm -f cluster.yaml storageclass-block.yaml storageclass-filesystem.yaml
```