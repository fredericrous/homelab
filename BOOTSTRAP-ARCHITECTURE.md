# Bootstrap Architecture: Using QNAP Vault as Secret Source

## Overview

This document describes how we use QNAP Vault as the source of truth for secrets during cluster bootstrap, solving the chicken-and-egg problem between Vault, cert-manager, and other services.

## The Problem

Traditional deployment has circular dependencies:
- Vault needs ingress with TLS certificates
- Ingress needs cert-manager for certificates
- cert-manager needs OVH credentials
- OVH credentials are stored in... Vault

## The Solution: Two-Vault Architecture

```
┌─────────────────┐         ┌──────────────────┐
│   QNAP Vault    │         │  Main K8s Vault  │
│  (Bootstrap)    │ ───────▶│   (Production)   │
│                 │ transit │                  │
│ - OVH creds     │ unseal  │ - App secrets    │
│ - AWS creds     │         │ - Uses transit   │
│ - Initial PKI   │         │   unseal         │
└─────────────────┘         └──────────────────┘
        │                            ▲
        │ provides                   │
        ▼ secrets                    │ stores
┌─────────────────┐                  │ secrets
│  cert-manager   │ ─────────────────┘
│  & other svcs   │   after bootstrap
└─────────────────┘
```

## Bootstrap Flow

1. **QNAP Setup** (Already complete)
   - Vault on K3s without cert-manager dependencies
   - Stores infrastructure secrets (OVH, AWS, etc.)
   - Acts as transit unseal master

2. **Main Cluster Bootstrap**
   ```bash
   # Stage 1-6: Basic cluster setup
   task stage1  # Create VMs
   task stage2  # Configure control plane
   task stage3  # Install CNI
   task stage4  # Configure workers
   task stage5  # Deploy ArgoCD
   task stage6  # Bootstrap DNS
   
   # Stage 7: Setup transit token (from QNAP)
   task stage7
   
   # Bootstrap secrets from QNAP Vault
   ./terraform/scripts/bootstrap-from-qnap.sh
   
   # Stage 8: Deploy core services (including Vault)
   task stage8
   ```

3. **Post-Bootstrap Migration**
   - Once main Vault is running, migrate secrets
   - Update applications to use main Vault
   - QNAP Vault continues as transit master only

## Advantages

1. **No Circular Dependencies**: QNAP Vault has no dependencies
2. **Single Source of Truth**: All secrets in one place during bootstrap
3. **Automatic Failover**: If main Vault fails, QNAP can provide secrets
4. **Clean Separation**: Infrastructure secrets vs application secrets

## Implementation

### Store Secrets in QNAP Vault

```bash
export VAULT_ADDR=http://192.168.1.42:61200
export VAULT_TOKEN=<qnap-vault-token>

# OVH DNS credentials for cert-manager
vault kv put secret/ovh-dns \
  applicationKey=<key> \
  applicationSecret=<secret> \
  consumerKey=<consumer>

# AWS credentials for backups
vault kv put secret/aws \
  access_key_id=<key> \
  secret_access_key=<secret>

# Harbor registry credentials
vault kv put secret/harbor \
  username=admin \
  password=<password>
```

### Bootstrap Script

The `bootstrap-from-qnap.sh` script:
1. Creates necessary namespaces
2. Copies secrets from QNAP Vault to K8s secrets
3. Allows services to start without circular dependencies

### Future Improvements

1. **Vault Agent**: Run Vault agent on K8s nodes to pull from QNAP
2. **External Secrets Operator**: Use ESO to sync from QNAP Vault
3. **Automated Migration**: Script to migrate secrets after bootstrap

## Security Considerations

1. **Network Isolation**: QNAP Vault only accessible from cluster network
2. **Transit Encryption**: All Vault communication is encrypted
3. **Minimal Exposure**: QNAP Vault only stores infrastructure secrets
4. **Audit Logging**: Both Vaults log all access

This architecture provides a clean, secure bootstrap process that leverages your existing infrastructure intelligently.