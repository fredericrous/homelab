# Automated Deployment Guide

This homelab deployment is designed to be as automated as possible, with minimal manual intervention.

## Architecture Overview

```
┌─────────────────┐         ┌──────────────────┐
│   QNAP NAS      │ ──────▶ │  Talos K8s       │
│                 │ transit │                  │
│ - Vault (K3s)   │ unseal  │ - Vault          │
│ - MinIO (K3s)   │         │ - ArgoCD GitOps  │
│ - Transit Keys  │         │ - All Services   │
└─────────────────┘         └──────────────────┘
```

## Quick Start

### 1. Deploy QNAP Services (One-time setup)

```bash
cd nas/
./deploy-k3s-services.sh

# After Vault is running, initialize it:
export VAULT_ADDR=http://192.168.1.42:61200
vault operator init -key-shares=1 -key-threshold=1

# Save the root token and unseal key!
vault operator unseal <unseal-key>
vault login <root-token>

# Setup transit for main cluster (stores token in Vault)
./setup-vault-transit-k3s.sh

# Optional: Store bootstrap secrets
./setup-vault-secrets.sh
```

### 2. Deploy Main Kubernetes Cluster

```bash
# Configure Terraform
cd terraform/
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your settings

# Deploy everything with automatic transit token retrieval
cd ..
export QNAP_VAULT_TOKEN=<qnap-root-token>
task deploy
```

## Automation Features

### 1. Transit Token Auto-Discovery

The deployment automatically retrieves the transit token from QNAP Vault:
- Uses `QNAP_VAULT_TOKEN` to connect to QNAP Vault
- Fetches the transit token from `secret/k8s-transit`
- Falls back to manual input if QNAP token is not provided

### 2. Secret Bootstrap

Stage 7 automatically creates placeholder secrets:
- `cert-manager/ovh-credentials` - Prevents cert-manager from failing
- Other namespace preparations

### 3. Vault Auto-Configuration

When Vault deploys, it:
- Automatically initializes (if using non-transit seal)
- Stores admin token and unseal keys in K8s secrets
- Configures Kubernetes auth
- Sets up policies for services

### 4. Resumable Deployment

Each stage is idempotent and can be resumed:
```bash
# Run specific stage
task stage7
task stage8

# Check status
task status
```

## Manual Steps (Currently Required)

### 1. QNAP Initial Setup
- Vault initialization (one-time)
- Root token login
- Transit token generation (automated by script)

### 2. Secrets Population
Real secrets need to be added to Vault:
```bash
# On QNAP or main cluster
vault kv put secret/ovh-dns \
  applicationKey=<key> \
  applicationSecret=<secret> \
  consumerKey=<consumer>

vault kv put secret/aws \
  access_key_id=<key> \
  secret_access_key=<secret>
```

## Environment Variables

### Required
- `QNAP_VAULT_TOKEN` - QNAP Vault root token (for automatic transit token retrieval)

### Optional
- `OVH_APPLICATION_KEY`, `OVH_APPLICATION_SECRET`, `OVH_CONSUMER_KEY`
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`

## Deployment Flow

1. **QNAP Setup** (`nas/deploy-k3s-services.sh`)
   - Deploys K3s
   - Deploys Vault and MinIO
   - Creates transit unseal key
   - Stores transit token

2. **Main Cluster** (`task deploy`)
   - Stage 1-6: Infrastructure setup
   - Stage 7: Transit token + bootstrap secrets
   - Stage 8: Core services (Vault, cert-manager, etc.)
   - Stage 9-10: Verification

3. **Post-Deployment**
   - Vault auto-configures via jobs
   - ArgoCD syncs all applications
   - Services use Vault for secrets

## Troubleshooting

### Transit Token Issues
```bash
# Check if token exists in QNAP
export VAULT_ADDR=http://192.168.1.42:61200
export VAULT_TOKEN=<qnap-root-token>
vault kv get secret/k8s-transit

# Regenerate if needed
cd nas/
./setup-vault-transit-k3s.sh
```

### Vault Not Initializing
```bash
# Check logs
kubectl logs -n vault vault-0
kubectl logs -n vault -l job-name=vault-init

# Manual init if needed
kubectl exec -n vault vault-0 -- vault operator init
```

### Cert-Manager Failing
The bootstrap creates placeholder secrets. Real credentials must be added:
```bash
# Add real OVH credentials to Vault
vault kv put secret/ovh-dns applicationKey=... applicationSecret=... consumerKey=...

# Or create K8s secret directly
kubectl create secret generic ovh-credentials \
  -n cert-manager \
  --from-literal=applicationKey=<key> \
  --from-literal=applicationSecret=<secret> \
  --from-literal=consumerKey=<consumer>
```

## Future Improvements

1. **Fully Automated QNAP Setup**
   - Auto-initialize Vault
   - Store root token securely
   - Eliminate manual steps

2. **External Secrets Operator**
   - Pull secrets from QNAP Vault automatically
   - No need for placeholder secrets

3. **Vault Agent on Nodes**
   - Direct secret injection
   - No K8s secrets needed

4. **CI/CD Integration**
   - GitHub Actions for deployment
   - Automated secret rotation