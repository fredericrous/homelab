# QNAP K3s Services

This directory contains scripts and configurations for running Vault and MinIO on QNAP NAS using K3s.

## Services

### Vault
- **Purpose**: Provides transit unsealing for Kubernetes Vault
- **Port**: NodePort 61200
- **Storage**: File backend at `/share/runtime/k3s/storage`
- **Role**: Stores transit keys for auto-unsealing main Kubernetes Vault

### MinIO
- **Purpose**: S3-compatible object storage for Velero backups
- **Ports**: NodePort 61900 (API), 61901 (Console)
- **Storage**: PVC at `/share/runtime/k3s/storage`
- **Role**: Primary backup destination with replication to AWS S3

## Architecture

```
3-Tier Backup Strategy:
┌─────────────────┐     ┌──────────────────┐     ┌──────────────────┐     ┌─────────────┐
│ Kubernetes      │     │ Kubernetes       │     │ QNAP MinIO       │     │ AWS S3      │
│ Velero          │────▶│ MinIO            │────▶│ (Long-term)      │────▶│ (Archive)   │
└─────────────────┘     └──────────────────┘     └──────────────────┘     └─────────────┘
                        Immediate backups       Sync >2 days old         Weekly sync
                                                    (daily)              (Sundays)

Vault Architecture:
┌─────────────────┐     ┌──────────────────┐
│ Kubernetes      │◀────│ QNAP Vault       │
│ Vault (Unsealed)│     │ (Transit Keys)   │
└─────────────────┘     └──────────────────┘
```

## Installation

K3s is pre-installed by QNAP. The kubeconfig is already available at `kubeconfig.yaml`.

### Deploy Services
```bash
# From project root directory
task nas:deploy

# Or from nas directory
task deploy

# The task will:
# - Create MinIO password secret (from Vault if available, or default)
# - Deploy all services
# - Setup AWS credentials if available
```

### Initialize Vault
```bash
# Show initialization instructions
task nas:vault-init

# Then run the manual commands:
export VAULT_ADDR=http://192.168.1.42:61200

# Initialize with 5 key shares and threshold of 3
vault operator init -key-shares=5 -key-threshold=3
# Save ALL the unseal keys and root token securely!

# Unseal Vault (requires 3 of the 5 keys)
vault operator unseal <unseal-key-1>
vault operator unseal <unseal-key-2>
vault operator unseal <unseal-key-3>

# Login with root token
export VAULT_TOKEN=<root-token>
vault login <root-token>

# Enable KV secrets engine
vault secrets enable -path=secret kv-v2

# Setup MinIO password and AWS credentials
task nas:vault-secrets

# AWS credentials will be automatically created if stored in Vault
# Or manually store them:
vault kv put secret/velero \
  aws_access_key_id=YOUR_KEY \
  aws_secret_access_key=YOUR_SECRET
```

### Setup Transit Unseal (for Main K8s Cluster)
```bash
# Make sure Vault is unsealed and you're logged in
export VAULT_ADDR=http://192.168.1.42:61200
export VAULT_TOKEN=<root-token>

task nas:vault-transit
# The transit token is automatically stored in Vault at secret/k8s-transit
```

#### Why 5 keys with threshold 3?
- **Security**: Multiple keys prevent single point of failure
- **Availability**: Only need 3 of 5 keys to unseal (can lose 2 keys)
- **Best Practice**: Distribute keys to different team members/locations

## Access

- **Vault UI**: http://192.168.1.42:61200
- **MinIO Console**: http://192.168.1.42:61901
  - Username: admin
  - Password: Stored in Vault at `secret/minio` (or `changeme123` if not set)
  - Retrieve: `vault kv get -field=root_password secret/minio`

## Backup Flow & Retention

1. **Kubernetes MinIO**: Immediate backups from Velero, kept for 7 days
2. **QNAP MinIO**: Long-term storage, 60-day retention (lifecycle policy)
3. **AWS S3**: Weekly sync from QNAP, keeps only 7 most recent backups

### Retention Summary
- **K8s MinIO**: 7 days (automatic cleanup via MinIO lifecycle policy)
- **QNAP MinIO**: 60 days (automatic cleanup via MinIO lifecycle policy)
- **AWS S3**: 7 backups (cleanup during weekly sync via CronJob)

### S3 Sync CronJob Details
- **Schedule**: Every Sunday at 2 AM (`0 2 * * 0`)
- **Image**: `minio/mc:RELEASE.2025-07-21T05-28-08Z`
- **Configuration**:
  - AWS credentials from `aws-credentials` secret
  - Syncs `qnap/velero-backups` to `aws/homelab-backups`
  - Scripts mounted from ConfigMap (see `minio/scripts/`)
- **Manual trigger**: `kubectl create job --from=cronjob/minio-s3-sync manual-sync -n minio`

## Benefits

- **Better Networking**: K3s provides reliable networking vs Docker Swarm issues
- **High Availability**: QNAP Vault is always available for unsealing
- **Tiered Storage**: Recent backups are fast, older ones archived
- **Cost Efficient**: Only long-term backups go to S3
- **Consistency**: Same Kubernetes patterns as main cluster

## Maintenance

### Check Status
```bash
# Check overall status
task nas:status

# View logs
task nas:logs -- vault
task nas:logs -- minio

# Direct kubectl commands
export KUBECONFIG=kubeconfig.yaml
kubectl get pods -A

# Check cronjob status
kubectl get cronjob -n minio
kubectl get jobs -n minio

# View S3 sync logs
kubectl logs -n minio -l job-name=minio-s3-sync-<tab-complete>
```

### Renew Transit Token
```bash
export VAULT_ADDR=http://192.168.1.42:61200
vault login <root-token>
vault token renew <transit-token>
```

## Files

- `Taskfile.yml`: Task automation for all NAS operations
  - `task deploy`: Deploy Vault and MinIO
  - `task vault-init`: Initialize Vault instructions
  - `task vault-secrets`: Configure secrets
  - `task vault-transit`: Setup transit unseal
  - `task status`: Check services status
  - `task logs`: View service logs
- `deploy-k3s-services.sh`: Service deployment script (wrapped by Taskfile)
- `setup-vault-secrets.sh`: Configure Vault secrets (wrapped by Taskfile)
- `setup-vault-transit-k3s.sh`: Transit unseal configuration (wrapped by Taskfile)
- `kubeconfig.yaml`: K3s cluster configuration (provided by QNAP)
- `minio/scripts/`: Shell scripts for MinIO jobs
  - `setup-lifecycle.sh`: Configures 60-day retention policy
  - `sync-to-s3.sh`: Syncs to AWS S3 with 7-backup retention
- `cert/`: Docker TLS certificates (legacy from Docker Swarm)