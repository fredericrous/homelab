# Vault Deployment Flow

This document clarifies how Vault is deployed in the homelab cluster to ensure it's only deployed once at the right time.

## Overview

Vault is deployed **ONCE** through the following automated flow:

```
1. QNAP Setup (Prerequisites)
   └─> Vault on K3s (transit master)
   └─> Transit token generated

2. Main Cluster Deployment
   ├─> Stage 7: Transit token secret created
   ├─> Stage 8: ArgoCD syncs Vault app
   └─> PostSync: Vault auto-initializes with transit unseal
```

## Detailed Flow

### 1. Prerequisites: QNAP Vault Setup
```bash
cd nas/
./deploy-k3s-services.sh
# Initialize and setup transit
./setup-vault-transit-k3s.sh
# Save the generated token!
```

### 2. Main Cluster Deployment (via Taskfile)

**Stage 7: Transit Token Setup** (`task stage7`)
- Runs `deploy-vault-transit.sh`
- Creates `vault-transit-token` secret in vault namespace
- This secret is required for Vault to start with transit unseal

**Stage 8: Core Services Sync** (`task stage8`)
- Terraform runs `sync-vault.sh`
- This syncs the Vault ArgoCD application
- Vault is deployed by ArgoCD (NOT manually)

### 3. How Vault Gets Deployed

1. **ApplicationSet Discovery**:
   - The core ApplicationSet finds `manifests/core/vault/app.yaml`
   - Creates an ArgoCD Application named "vault"

2. **ArgoCD Sync**:
   - `sync-vault.sh` triggers the sync
   - ArgoCD applies all resources in `manifests/core/vault/`

3. **Vault Initialization**:
   - PreSync: `job-configure-transit-token.yaml` validates token exists
   - Main: Vault StatefulSet deploys with transit unseal config
   - PostSync: `job-vault-init-simplified.yaml` initializes Vault

## Why This Flow?

1. **Single Deployment**: Vault is deployed exactly once via ArgoCD
2. **Proper Ordering**: Transit token exists before Vault starts
3. **GitOps**: All configuration in Git, only secret managed externally
4. **Auto-Unseal**: No manual intervention after restarts

## Common Issues

### "Vault deployed multiple times"
**This doesn't happen because:**
- Stage 7 only creates the transit token secret
- Stage 8 only syncs the existing ArgoCD app
- ArgoCD ensures idempotent deployment

### "Transit token missing"
**Solution:**
```bash
kubectl create secret generic vault-transit-token \
  --namespace=vault \
  --from-literal=token=<TOKEN_FROM_QNAP>
```

### "Vault won't initialize"
**Check:**
1. Transit token secret exists
2. QNAP Vault is accessible from cluster
3. Check init job logs: `kubectl logs -n vault -l job-name=vault-init`

## File Locations

- **Vault Manifests**: `manifests/core/vault/`
- **ArgoCD App Config**: `manifests/core/vault/app.yaml`
- **ApplicationSet**: `manifests/argocd/root/applicationset-core.yaml`
- **Sync Script**: `terraform/scripts/sync-vault.sh`
- **Transit Setup**: `terraform/scripts/deploy-vault-transit.sh`