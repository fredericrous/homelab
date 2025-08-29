# Vault Initialization Issue

## Problem
Vault 1.17.6 appears to be "auto-initializing" when starting with a new PVC. This is actually caused by Rook-Ceph persistent storage retaining old Vault data even after PVC deletion.

## Root Cause
When we delete and recreate the PVC, Rook-Ceph may be:
1. Using snapshots or backups to restore data
2. Not fully cleaning up the underlying storage
3. Reusing the same physical volume with existing data

## Solutions

### Option 1: Use Vault Helm Chart (Recommended)
Instead of manual StatefulSet, use the official Vault Helm chart which handles initialization properly:

```yaml
helmCharts:
- name: vault
  repo: https://helm.releases.hashicorp.com
  version: 0.28.1
  namespace: vault
  releaseName: vault
  valuesInline:
    server:
      dataStorage:
        enabled: true
        size: 10Gi
        storageClass: rook-ceph-block
```

### Option 2: Force Clean Storage
1. Scale down Vault: `kubectl scale sts -n vault vault --replicas=0`
2. Delete PVC: `kubectl delete pvc -n vault vault-data`
3. Find and delete the PV: `kubectl get pv | grep vault`
4. Wait for PV to be fully deleted
5. Check Rook-Ceph for any lingering volumes
6. Recreate everything

### Option 3: Change Storage Class
Use a different storage class that doesn't retain data:
- local-path-provisioner
- A new Rook-Ceph pool with different retention settings

### Option 4: Use Different Storage Backend
Instead of file storage, use:
- Consul
- etcd
- Raft (built-in)

## Current Workaround
We've created placeholder secrets to unblock the deployment, but this means:
- Vault operations will fail (can't read/write secrets)
- The real initialization keys are lost
- Manual intervention is required to properly initialize Vault

## Proper Fix for Production
1. Switch to Vault Helm chart for proper lifecycle management
2. Implement auto-unseal with cloud KMS to avoid key management issues
3. Ensure storage backend is properly cleaned between deployments
4. Use Vault's Raft storage instead of file storage for better control