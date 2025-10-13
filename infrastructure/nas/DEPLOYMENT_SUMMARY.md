# QNAP K3s Deployment Summary

## What's Automated

1. **Deployment Script (`deploy-k3s-services.sh`)**:
   - ✅ Deploys base resources (storage class)
   - ✅ Deploys Vault and MinIO using Kustomize with Helm
   - ✅ Creates MinIO password secret (from Vault if available)
   - ✅ Waits for services to be ready
   - ✅ Checks if Vault is initialized
   - ✅ Creates AWS credentials secret if environment variables are set
   - ✅ Provides context-aware post-deployment instructions

2. **MinIO Setup**:
   - ✅ Secure password generation with `setup-vault-secrets.sh`
   - ✅ Password stored in Vault at `secret/minio`
   - ✅ AWS credentials setup with `setup-vault-secrets.sh`
   - ✅ Automatic bucket creation (`velero-backups`)
   - ✅ Lifecycle policy job (60-day retention)
   - ✅ S3 sync cronjob configuration
   - ✅ AWS credentials from Kubernetes secret

3. **Directory Structure**:
   - ✅ `qnap/base/` - Contains storage class (properly used)
   - ✅ `qnap/vault/` - Vault with NodePort 61200
   - ✅ `qnap/minio/` - MinIO with NodePorts 61900/61901

## Manual Steps Still Required

1. **Initial Vault Setup** (one-time):
   ```bash
   export VAULT_ADDR=http://192.168.1.42:61200
   vault operator init -key-shares=5 -key-threshold=3
   vault operator unseal <key-1>
   vault operator unseal <key-2>
   vault operator unseal <key-3>
   vault login <root-token>
   vault secrets enable -path=secret kv-v2
   ```

2. **AWS Credentials** (if not in environment):
   ```bash
   kubectl -n minio create secret generic aws-credentials \
     --from-literal=aws_access_key_id=YOUR_KEY \
     --from-literal=aws_secret_access_key=YOUR_SECRET
   ```

3. **Transit Unseal Setup** (for main K8s cluster):
   ```bash
   ./setup-vault-transit-k3s.sh
   ```

## Key Improvements Made

1. **Fixed S3 Sync**:
   - Changed from Vault CLI to environment variables (mc container doesn't have vault)
   - Created dedicated `aws-credentials` secret
   - Fixed S3 endpoint configuration

2. **Enhanced Documentation**:
   - Added cronjob details and manual trigger commands
   - Documented directory structure
   - Added troubleshooting for S3 sync
   - Updated backup tier descriptions

3. **Better Automation**:
   - Deploy script checks for existing resources
   - Post-deployment tasks are automated where possible
   - Context-aware instructions based on current state

4. **Improved Security**:
   - MinIO password generated securely and stored in Vault
   - Removed hardcoded password from kustomization
   - Deploy script handles both Vault-available and Vault-unavailable scenarios

## Cronjob Configuration

- **Schedule**: `0 2 * * 0` (Sundays at 2 AM)
- **Image**: `minio/mc:RELEASE.2025-07-21T05-28-08Z`
- **Environment**: AWS credentials from secret
- **Scripts**: Mounted via ConfigMap from `/nas/minio/scripts/`
- **Manual Test**: `kubectl create job --from=cronjob/minio-s3-sync test-sync -n minio`

## Monitoring Commands

```bash
# Check cronjob schedule
kubectl get cronjob -n minio

# View recent jobs
kubectl get jobs -n minio

# Check S3 sync logs
kubectl logs -n minio -l job-name=minio-s3-sync-<timestamp>

# Verify AWS credentials
kubectl describe secret aws-credentials -n minio
```