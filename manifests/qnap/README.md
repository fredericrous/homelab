# QNAP K3s Services

This directory contains Kubernetes manifests for running Vault and MinIO on QNAP using K3s.

## Prerequisites

1. QNAP NAS with K3s pre-installed
2. kubectl installed on your local machine
3. kubeconfig available at `nas/kubeconfig.yaml`

## Installation

### Deploy Services

```bash
# Run deployment script
./nas/deploy-k3s-services.sh

# The script will:
# 1. Deploy base resources (storage class)
# 2. Deploy Vault with NodePort 61200
# 3. Create MinIO password secret (from Vault if available)
# 4. Deploy MinIO with NodePorts 61900 (API) and 61901 (Console)
# 5. Check for AWS credentials and create secret if available
# 6. Display post-deployment instructions
```

### Initialize and Configure Vault

```bash
# Initialize Vault with 5 key shares and threshold of 3
export VAULT_ADDR=http://192.168.1.42:61200
vault operator init -key-shares=5 -key-threshold=3

# Save ALL the unseal keys and root token securely!
# Example output:
# Unseal Key 1: xxx...
# Unseal Key 2: xxx...
# Unseal Key 3: xxx...
# Unseal Key 4: xxx...
# Unseal Key 5: xxx...
# Initial Root Token: hvs.xxx...

# Unseal Vault (requires 3 of the 5 keys)
vault operator unseal <unseal-key-1>
vault operator unseal <unseal-key-2>
vault operator unseal <unseal-key-3>

# Login with root token
export VAULT_TOKEN=<root-token>
vault login <root-token>

# Enable KV secrets engine
vault secrets enable -path=secret kv-v2

# Setup MinIO password and AWS credentials (recommended)
./nas/setup-vault-secrets.sh

# Add AWS credentials for MinIO S3 sync (if you have them)
vault kv put secret/velero \
  aws_access_key_id=YOUR_AWS_ACCESS_KEY \
  aws_secret_access_key=YOUR_AWS_SECRET

# Create AWS credentials secret for MinIO S3 sync
kubectl -n minio create secret generic aws-credentials \
  --from-literal=aws_access_key_id=YOUR_AWS_ACCESS_KEY \
  --from-literal=aws_secret_access_key=YOUR_AWS_SECRET
```

## Services

### Vault
- **URL**: http://192.168.1.42:61200
- **Purpose**: Transit unsealing for main Kubernetes cluster Vault
- **Storage**: File backend on local disk

### MinIO
- **API URL**: http://192.168.1.42:61900
- **Console URL**: http://192.168.1.42:61901
- **Credentials**: 
  - Username: admin
  - Password: Stored in Vault at `secret/minio`
  - Retrieve: `vault kv get -field=root_password secret/minio`
  - Default: `changeme123` (if Vault not available during deployment)
- **Purpose**: S3-compatible storage for backups
- **Features**: 
  - Secure password generation via `setup-vault-secrets.sh`
  - Lifecycle policy: 60-day retention on QNAP
  - Weekly S3 sync cronjob (Sundays at 2 AM)
  - AWS S3 cleanup: keeps only 7 most recent backups

## Architecture

```
┌─────────────────────────────────────────┐
│              QNAP K3s                   │
├─────────────────────────────────────────┤
│  ┌─────────┐         ┌─────────┐       │
│  │  Vault  │         │  MinIO  │       │
│  │ (Transit)│         │ (S3)    │       │
│  └────┬────┘         └────┬────┘       │
│       │                   │             │
│  NodePort:61200      NodePort:61900/1  │
└───────┴───────────────────┴────────────┘
           │                    │
           ▼                    ▼
    Main K8s Cluster      Backup Storage
```

## Backup Strategy

1. **Tier 1**: MinIO on main Kubernetes cluster (immediate access, 7 days)
2. **Tier 2**: MinIO on QNAP (long-term storage, 60 days)
3. **Tier 3**: AWS S3 (weekly sync, 7 most recent backups only)

### S3 Sync CronJob
- **Schedule**: `0 2 * * 0` (Every Sunday at 2 AM)
- **Container**: `minio/mc:RELEASE.2025-07-21T05-28-08Z`
- **Process**:
  1. Reads AWS credentials from `aws-credentials` secret
  2. Syncs `velero-backups` bucket to AWS S3 `homelab-backups`
  3. Cleans up old backups on S3 (keeps 7 most recent)
- **Scripts**: Located in ConfigMap from `/nas/minio/scripts/`

## Maintenance

### Check Service Status
```bash
export KUBECONFIG=~/.kube/config-qnap
kubectl get pods -A
kubectl -n vault logs -l app.kubernetes.io/name=vault
kubectl -n minio logs -l app=minio
```


### Access MinIO Console
1. Browse to http://192.168.1.42:61901
2. Login with admin / changeme123

## Directory Structure

```
manifests/qnap/
├── base/                    # Shared base resources
│   ├── kustomization.yaml
│   └── storage-class.yaml   # QNAP local-path storage class
├── vault/                   # Vault deployment
│   ├── kustomization.yaml   # Helm chart integration
│   ├── namespace.yaml
│   ├── pvc.yaml            # 10Gi persistent volume
│   └── values.yaml         # Helm values (NodePort 61200)
└── minio/                   # MinIO deployment
    ├── kustomization.yaml   # Helm chart + custom resources
    ├── namespace.yaml
    ├── pvc.yaml            # 50Gi persistent volume
    ├── values.yaml         # Helm values (NodePorts 61900/61901)
    ├── cronjob-s3-sync.yaml # Weekly AWS S3 sync
    ├── job-setup-lifecycle.yaml # 60-day retention policy
    └── scripts/            # Shell scripts for jobs
        ├── setup-lifecycle.sh
        └── sync-to-s3.sh
```

## Troubleshooting

### K3s won't start
- Check logs: `ssh admin@192.168.1.42 "sudo journalctl -u k3s -f"`
- Ensure sufficient disk space in /share/runtime/k3s

### Services not accessible
- Check NodePort services: `kubectl get svc -A`
- Verify no firewall blocking ports 61200, 61900, 61901
- Check pod status: `kubectl get pods -A`
- Note: QNAP K3s restricts NodePort range to 61000-62000

### Vault is sealed after restart
- Vault seals automatically when restarted
- You need to unseal it again with 3 keys:
  ```bash
  export VAULT_ADDR=http://192.168.1.42:61200
  vault operator unseal <key-1>
  vault operator unseal <key-2>
  vault operator unseal <key-3>
  ```

### Storage issues
- K3s uses local-path provisioner (defined in base/storage-class.yaml)
- Data stored in /share/runtime/k3s/storage
- Ensure sufficient disk space

### S3 Sync Issues
- Check cronjob status: `kubectl get cronjob -n minio`
- View last job: `kubectl get jobs -n minio`
- Check logs: `kubectl logs -n minio -l job-name=minio-s3-sync-<timestamp>`
- Verify AWS credentials: `kubectl get secret aws-credentials -n minio`
- Manual trigger: `kubectl create job --from=cronjob/minio-s3-sync test-sync -n minio`