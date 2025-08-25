# Velero Backup Solution

This directory contains the Velero backup solution for the homelab Kubernetes cluster.

## Features

- Automated backup of all namespaces with PVCs
- CSI snapshot support for Rook-Ceph volumes
- S3-compatible backend storage
- Vault integration for credentials
- Scheduled backups every 2 days with 30-day retention

## Prerequisites

1. S3-compatible storage (MinIO, AWS S3, etc.)
2. Vault configured with Kubernetes auth
3. Rook-Ceph CSI drivers (for snapshot support)

## Installation

1. **Configure S3 credentials in Vault:**
   ```bash
   cd manifests/backup/base
   ./vault-populate-secrets.sh
   # Then update the secret with actual credentials:
   vault kv put secret/velero \
     aws_access_key_id="YOUR_ACCESS_KEY" \
     aws_secret_access_key="YOUR_SECRET_KEY"
   ```

2. **Set environment variables:**
   ```bash
   export BUCKET_NAME="velero-backups"
   export REGION="us-east-1"
   export S3_URL="http://your-minio:9000"
   ```

3. **Run the preparation script:**
   ```bash
   cd manifests/backup/ci
   ./prepare-velero.sh
   ```

4. **Deploy Velero:**
   ```bash
   cd manifests/backup/base
   kubectl apply -k .
   ```

5. **Run smoke test:**
   ```bash
   cd manifests/backup/ci
   ./test-velero.sh
   ```

## Usage

### Manual backup
```bash
kubectl exec -n velero deployment/velero -- velero backup create manual-backup --include-namespaces my-namespace
```

### List backups
```bash
kubectl exec -n velero deployment/velero -- velero backup get
```

### Restore from backup
```bash
kubectl exec -n velero deployment/velero -- velero restore create --from-backup backup-name
```

### Check schedules
```bash
kubectl exec -n velero deployment/velero -- velero schedule get
```

## Architecture

- **Velero Server**: Main backup controller
- **Node Agent**: DaemonSet for volume backups
- **CSI Snapshotter**: Handles Rook-Ceph snapshots
- **Schedules**: Auto-generated for each namespace with PVCs

## Excluded Namespaces

System namespaces are automatically excluded:
- kube-*
- rook-*
- metallb-*
- cert-manager
- vault-secrets-operator
- linkerd
- cilium
- node-feature-discovery