# Vault Configuration Pipeline

This directory contains the complete Vault setup pipeline for the homelab cluster.

## Overview

Vault is deployed as a StatefulSet with transit auto-unseal using an external QNAP Vault instance. The setup is divided into multiple stages, each handled by a dedicated Kubernetes Job.

## Pipeline Stages

### Stage 0: Prerequisites (sync-wave: -1)
- **Transit Token Secret**: Created by Terraform before Vault deployment
  - Secret: `vault-transit-token` in namespace `vault`
  - Contains token for QNAP Vault transit unseal

### Stage 1: Vault StatefulSet (sync-wave: 0)
- **Resources**:
  - StatefulSet: Single replica Vault server
  - PVC: Persistent storage for Vault data
  - Service: ClusterIP service for internal access
  - Ingress: External access via HAProxy

### Stage 2: Initialization (sync-wave: 2)
- **Job**: `vault-init`
- **Purpose**: Initialize Vault with transit auto-unseal
- **Outputs**:
  - `vault-admin-token`: Root token for admin access
  - `vault-keys`: Recovery keys (not needed for unseal with transit)
- **Health Checks**:
  - Waits for Vault pod to be ready
  - Verifies transit token is not placeholder
  - Checks Vault health endpoint

### Stage 3: KV Engine Configuration (sync-wave: 3)
- **Job**: `vault-configure-kv`
- **Purpose**: Enable KV v2 secret engine at `secret/`
- **Dependencies**: 
  - Vault must be initialized
  - Admin token must exist
- **Health Checks**:
  - Verifies Vault is unsealed
  - Tests KV engine with write/read

### Stage 4: Authentication Setup (sync-wave: 4)
- **Job**: `vault-configure-argocd`
- **Purpose**: Configure Kubernetes auth for ArgoCD
- **Configures**:
  - Kubernetes auth method
  - Service account bindings
  - Policies for ArgoCD access

### Stage 5: Application Access (sync-wave: 5)
- **Jobs**:
  - `vault-configure-app-ovh`: OVH DNS credentials access
  - `vault-configure-cert-manager`: cert-manager Vault access
  - `vault-configure-eso`: External Secrets Operator access
- **Purpose**: Set up specific application access patterns

### Stage 6: Post-Initialization (sync-wave: 6)
- **Script**: `vault-post-init.sh` (run by Terraform)
- **Purpose**: Upload initial secrets like client CA
- **Dependencies**:
  - All previous stages must be complete
  - KV engine must be enabled

## Secret Paths

| Path | Purpose | Consumers |
|------|---------|-----------|
| `secret/client-ca` | mTLS Client CA certificate | HAProxy Ingress |
| `secret/ovh-dns` | OVH API credentials | cert-manager webhook |
| `secret/velero` | S3 backup credentials | Velero |
| `secret/nfs` | NFS share credentials | CSI driver |
| `secret/<app>/*` | Application-specific secrets | Various apps |

## Troubleshooting

### Vault is sealed
```bash
# Check seal status
kubectl exec -n vault vault-0 -- vault status

# If using transit unseal, check the transit token
kubectl get secret vault-transit-token -n vault -o jsonpath='{.data.token}' | base64 -d

# Restart pod to trigger auto-unseal
kubectl delete pod -n vault vault-0
```

### Missing KV engine
```bash
# Check if KV engine is enabled
kubectl exec -n vault vault-0 -- vault secrets list

# Manually run the configure-kv job
kubectl delete job -n vault vault-configure-kv
kubectl apply -f job-vault-configure-kv.yaml
```

### Job failures
```bash
# Check job logs
kubectl logs -n vault job/vault-init
kubectl logs -n vault job/vault-configure-kv

# Check job status
kubectl describe job -n vault <job-name>
```

## Security Considerations

1. **Transit Token**: Never commit the transit token. It's managed by Terraform and stored as a K8s secret
2. **Root Token**: Only used for initial configuration, should be revoked after setup
3. **Least Privilege**: Each app gets its own auth role with minimal required permissions
4. **Audit Logging**: Vault audit logs are enabled and stored in the PVC

## Dependencies Graph

```
vault-transit-token (Terraform)
    ↓
vault StatefulSet
    ↓
vault-init Job
    ↓
vault-configure-kv Job
    ↓
vault-configure-* Jobs (parallel)
    ↓
Application deployments (ESO, cert-manager, etc.)
```