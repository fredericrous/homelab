# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a homelab GitOps repository that manages a Kubernetes cluster running on Talos Linux, deployed on Proxmox VMs using Terraform. The cluster uses FluxCD for GitOps with Kustomize for application deployment and Vault for secrets management.

## Key Commands

### Cluster Deployment
```bash
# Setup configuration
cp .env.example .env  # Configure with your settings including VAULT_TRANSIT_TOKEN
cd terraform
cp terraform.tfvars.example terraform.tfvars  # Configure Proxmox settings
cd ..

# Option 1: Full installation
task install     # Creates cluster, bootstraps Flux, verifies infrastructure

# Option 2: Step by step (recommended for production)
task up          # Create cluster (VMs + Talos + CNI)
task bootstrap   # Bootstrap FluxCD (will prompt for GitHub token)
task verify      # Verify all infrastructure components

# Individual operations:
task provision   # Create VMs
task configure   # Configure Talos  
task kubeconfig  # Get kubeconfig
task down        # Stop cluster (keeps VMs)
task uninstall   # Remove everything
```

### Application Deployment
```bash
# Deploy application with kustomize (from manifests/<app>/)
kubectl apply -k .

# Check deployment status
kubectl get pods,svc,ingress -n <namespace>

# Force ESO to refresh secrets
kubectl annotate externalsecret <name> -n <namespace> force-sync=$(date +%s) --overwrite
```

### Vault Operations
```bash
# Access Vault
kubectl port-forward -n vault svc/vault 8200:8200
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$(kubectl get secret vault-admin-token -n vault -o jsonpath='{.data.token}' | base64 -d)

# Unseal Vault (required after restart)
kubectl exec -n vault vault-0 -- vault operator unseal $(kubectl get secret vault-keys -n vault -o jsonpath='{.data.unseal-key}' | base64 -d)

# View/manage secrets
vault kv list secret/
vault kv get secret/<path>
vault kv put secret/<path> key=value
```

### Lint and Validation
```bash
# Validate kustomization
kubectl kustomize . --enable-helm

# Check YAML syntax
kubectl apply -k . --dry-run=client
```

## Architecture

### Directory Organization
Services are organized into:
- `manifests/core/` - Infrastructure services (Vault, cert-manager, storage, etc.)
- `manifests/apps/` - User applications (Nextcloud, Plex, Harbor, etc.)
- `manifests/base/` - Shared reusable configurations

### Infrastructure Layer (Terraform)
- **Proxmox VMs**: 1 control plane + 2 workers (one with GPU passthrough)
- **Talos Linux**: Immutable Kubernetes OS
- **Network**: Static IPs via DHCP reservations or Talos config
- **Storage**: Local-path for control plane, Rook-Ceph for persistent storage

### Core Services Stack
1. **CNI**: Cilium (advanced networking, no kube-proxy)
2. **Storage**: Rook-Ceph (distributed storage) + SMB CSI driver
3. **Ingress**: HAProxy with mTLS client certificates
4. **Secrets**: Vault (using Raft storage) + Vault Secrets Operator (VSO)
5. **Certificates**: cert-manager with OVH DNS-01 webhook
6. **Database**: CloudNativePG (PostgreSQL operator)
7. **Identity**: LLDAP + Authelia (authentication/authorization)

### Application Deployment Pattern
Each application in `manifests/` follows this structure:
- `kustomization.yaml`: Main deployment manifest
- `namespace.yaml`: Dedicated namespace
- `*-vault-secret.yaml`: VaultStaticSecret for pulling secrets from Vault
- `*-vault-auth.yaml`: VaultAuth for namespace authentication
- `deployment.yaml` + patches: Main workload with customizations
- `ingress.yaml`: HAProxy ingress with mTLS

### Secrets Management Flow
1. Secrets stored in Vault at `secret/<app>/*`
2. VaultStaticSecret resources sync to Kubernetes secrets
3. Deployments reference the synced secrets
4. VSO handles rotation and updates

### GitOps Principles
- All resources are idempotent (safe to apply multiple times)
- Jobs check existing state before executing
- Database creation jobs verify if resources exist
- Vault population jobs skip if secrets already present

## Critical Paths

### Vault Must Be Initialized First
```bash
# Deploy Vault and initialize it
kubectl apply -k manifests/vault/
# The job-vault-init.yaml will automatically initialize Vault and store keys in secrets
# Keys are stored in vault-keys and vault-admin-token secrets in the vault namespace
```

### Service Dependencies
1. Vault → All services (for secrets)
2. CloudNativePG → Services needing PostgreSQL
3. cert-manager → Services needing TLS certificates
4. LLDAP → Authelia → Services needing authentication

### mTLS Configuration
- Client CA at `manifests/client-ca/ca/`
- HAProxy validates client certificates for `*x.daddyshome.fr`
- Mobile endpoints use separate ingress without mTLS (e.g., `drive-mobilex.daddyshome.fr`)

## Known Issues


## Vault Token and Keys
Vault is automatically initialized by the `job-vault-init.yaml` job, which stores:
- Admin token in `vault-admin-token` secret
- Unseal key in `vault-keys` secret
- Both in the `vault` namespace

To retrieve these values:
```bash
# Get admin token
kubectl get secret vault-admin-token -n vault -o jsonpath='{.data.token}' | base64 -d

# Get unseal key
kubectl get secret vault-keys -n vault -o jsonpath='{.data.unseal-key}' | base64 -d
```

## Known Issues

### Cilium and kube-proxy
- Cilium is configured with `kubeProxyReplacement: true` to replace kube-proxy functionality
- Talos cluster configuration has `proxy.disabled: true` to prevent kube-proxy from being deployed
- Environment variable substitution for `${ARGO_CONTROL_PLANE_IP}` in Cilium values must be done during terraform deployment
- The terraform script also checks and removes any existing kube-proxy DaemonSet during Cilium deployment

### Environment Variable Substitution
- Both Cilium and ArgoCD require environment variable substitution during terraform deployment
- Variables that need substitution:
  - `${ARGO_CONTROL_PLANE_IP}` - Used in Cilium configuration
  - `${ARGO_EXTERNAL_DOMAIN}` - Used in ArgoCD configuration
- The terraform scripts:
  - Load variables from the `.env` file
  - Create temporary values files with substituted variables
  - Install/upgrade using Helm with the substituted values
  - Clean up temporary files
