# Nextcloud Deployment

This directory contains the Kubernetes manifests and scripts for deploying Nextcloud with the following features:

- PostgreSQL database integration
- Redis caching
- NFS storage support
- LLDAP authentication
- HashiCorp Vault for secrets management
- HAProxy with mTLS protection
- Automated TLS certificates via cert-manager

## Prerequisites

- Kubernetes cluster with:
  - PostgreSQL operator (postgres-apps cluster)
  - Redis deployment (redis-standalone in ot-operators namespace)
  - LLDAP deployment
  - HashiCorp Vault
  - cert-manager
  - HAProxy ingress controller
  - NFS CSI driver (optional)

## Quick Start

### Deploy Nextcloud

```bash
./deploy-nextcloud.sh
```

This script will:
1. Configure secrets in Vault (or use existing ones)
2. Create PostgreSQL database and user
3. Deploy Nextcloud using Kustomize
4. Install Nextcloud if not already installed
5. Configure Redis caching
6. Optionally configure LDAP authentication

### Remove Nextcloud

```bash
./cleanup-nextcloud.sh
```

This script allows you to:
- Remove Nextcloud deployment
- Optionally remove PostgreSQL database
- Optionally remove Vault secrets
- Optionally remove entire namespace and PVCs

## Manual Deployment Steps

If you prefer to deploy manually:

1. **Configure Vault secrets:**
   ```bash
   ./configure-nextcloud-vault.sh
   ```

2. **Deploy Nextcloud:**
   ```bash
   kubectl apply -k .
   ```

3. **Manually create database:**
   ```bash
   kubectl exec -n postgres postgres-apps-rw-0 -- psql -U postgres
   CREATE USER nextcloud WITH PASSWORD 'your-password';
   CREATE DATABASE nextcloud OWNER nextcloud;
   GRANT ALL PRIVILEGES ON DATABASE nextcloud TO nextcloud;
   ```

4. **Wait for pods to be ready:**
   ```bash
   kubectl wait --for=condition=ready pod -l app=nextcloud -n nextcloud --timeout=600s
   ```

5. **Configure LDAP:**
   ```bash
   ./configure-ldap.sh
   ```

## Vault Credentials

The deployment scripts retrieve Vault credentials from Kubernetes secrets:
- **Unseal Key**: Retrieved from `vault-keys` secret in `vault` namespace
- **Root Token**: Retrieved from `vault-admin-token` secret in `vault` namespace

## Access

- **URL**: https://drive.daddyshome.fr
- **Admin Credentials**: Stored in Vault at `secret/nextcloud`

To retrieve admin credentials:
```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$(kubectl get secret vault-admin-token -n vault -o jsonpath='{.data.token}' | base64 -d)
vault kv get -field=admin-username secret/nextcloud
vault kv get -field=admin-password secret/nextcloud
```

## Configuration

### Required Secrets in Vault

Before deployment, ensure these secrets are properly set in Vault:
- `smb-password`: Password for SMB storage access
- `ldap-bind-password`: Password for LLDAP bind user

Update them with:
```bash
vault kv patch secret/nextcloud smb-password='your-smb-password'
vault kv patch secret/nextcloud ldap-bind-password='your-lldap-password'
```

### mTLS Configuration

The deployment uses HAProxy with **required** mTLS verification for security. This works because we use DNS-01 challenges for certificate renewal, which don't require HTTP access.

### Certificate Management with OVH DNS

Certificates are managed using Let's Encrypt with OVH DNS-01 challenges:

1. **Manual certificate generation** (if cert-manager webhook fails):
   ```bash
   ./get-cert-ovh-dns.sh
   ```

2. **Automatic renewal**: The certificate will auto-renew 30 days before expiry using DNS-01 challenges, which work perfectly with mTLS enabled.

## Files

- `deploy-nextcloud.sh` - Main deployment script
- `cleanup-nextcloud.sh` - Cleanup/removal script
- `kustomization.yaml` - Kustomize configuration
- `namespace.yaml` - Nextcloud namespace
- `secrets.yaml` - Secret templates (synced from Vault)
- `vault-secret-sync.yaml` - CronJob for Vault synchronization
- `configmap.yaml` - PHP, Apache, and Nextcloud configuration
- `deployment.yaml` - Main Nextcloud deployment
- `service.yaml` - Kubernetes service
- `ingress.yaml` - HAProxy ingress with mTLS
- `postgres-setup.yaml` - PostgreSQL setup job (currently disabled)
- `configure-ldap.sh` - Manual LDAP configuration script
- `configure-nextcloud-vault.sh` - Vault configuration script

## Features Configured

- **Storage:**
  - Local storage: 50GB for Nextcloud data (rook-ceph-block)
  - SMB storage: 100GB mounted at `/mnt/smb` (currently disabled)
  
- **Performance:**
  - Redis caching for distributed cache and locking
  - APCu for local caching
  - Optimized PHP settings (512M memory, 10G upload limit)

- **Security:**
  - mTLS client certificate (optional for ACME, can be set to required)
  - LDAP authentication via LLDAP
  - All secrets managed by Vault
  - HTTPS only access
  - Automatic secret rotation via CronJob

## Troubleshooting

### Check deployment status
```bash
kubectl get pods -n nextcloud
kubectl logs -n nextcloud -l app=nextcloud
```

### Check certificate status
```bash
kubectl get certificate -n nextcloud nextcloud-tls
kubectl describe certificate -n nextcloud nextcloud-tls
```

### Manual Vault sync
```bash
kubectl create job --from=cronjob/vault-secret-sync manual-sync-$(date +%s) -n nextcloud
```

### Access Nextcloud CLI
```bash
POD=$(kubectl get pods -n nextcloud -l app=nextcloud -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n nextcloud $POD -c nextcloud -- php occ status
```

### Common Issues

1. **SMB Mount**: Currently disabled due to credential mounting issues. Uncomment in `deployment.yaml` after fixing SMB credentials.

2. **Certificate Issuance**: If mTLS is set to "required", cert-manager cannot complete ACME challenges. The ingress is configured with "optional" to allow initial certificate issuance.

3. **Initial Setup**: Nextcloud may take a few minutes to complete initial setup after first deployment.

4. **Database Connection**: Ensure PostgreSQL database exists and credentials in Vault match.

5. **Redis Connection**: Verify Redis is running in ot-operators namespace.
