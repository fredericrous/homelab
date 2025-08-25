# LLDAP and Authelia Vault Integration

This document describes how LLDAP and Authelia secrets are managed using HashiCorp Vault.

## Overview

Both LLDAP and Authelia secrets are stored in Vault and synchronized to Kubernetes secrets using CronJobs that run every 5 minutes. This provides centralized secret management and automatic rotation capabilities.

## Initial Setup

1. **Ensure Vault is initialized and unsealed**:
   ```bash
   # Check Vault status
   kubectl -n vault exec vault-0 -- vault status
   ```

2. **Configure secrets in Vault**:
   Secrets are automatically configured by GitOps jobs included in each application's kustomization:
   - LLDAP: `job-vault-configure-lldap.yaml` configures Vault policies and auth
   - Authelia: `vault-policy-update-job.yaml` and `vault-populate-secrets-job.yaml` handle configuration

3. **Deploy the applications**:
   ```bash
   # Deploy LLDAP
   kubectl apply -k manifests/lldap/
   
   # Deploy Authelia
   kubectl apply -k manifests/authelia/
   ```

## Secret Structure

### LLDAP Secrets (stored at `secret/lldap`)
- `database-url`: PostgreSQL connection string
- `jwt-secret`: JWT signing secret
- `ldap-user-pass`: LDAP admin password
- `key-seed`: Encryption key seed

### Authelia Secrets (stored at `secret/authelia`)
- `jwt-secret`: JWT signing secret
- `session-secret`: Session encryption secret
- `storage-encryption-key`: Storage encryption key
- `storage-password`: PostgreSQL password
- `smtp-password`: SMTP password (if using email notifications)
- `authentication-backend-ldap-password`: LDAP bind password

## How It Works

1. **Service Accounts**: Each application has its own service account with permissions to manage secrets in its namespace.

2. **Vault Authentication**: The CronJobs use Kubernetes auth to authenticate with Vault using their service account tokens.

3. **Secret Synchronization**: Every 5 minutes, the CronJobs:
   - Authenticate with Vault
   - Fetch the latest secrets
   - Create or update the Kubernetes secrets

4. **Application Usage**: The applications mount the synchronized Kubernetes secrets as files.

## Updating Secrets

To update secrets, modify them in Vault:

```bash
# Port forward to Vault
kubectl -n vault port-forward svc/vault 8200:8200

# Update LLDAP secrets
vault kv put secret/lldap \
  database-url="new-connection-string" \
  jwt-secret="new-jwt-secret" \
  ldap-user-pass="new-admin-password" \
  key-seed="new-key-seed"

# Update Authelia secrets
vault kv put secret/authelia \
  jwt-secret="new-jwt-secret" \
  session-secret="new-session-secret" \
  storage-encryption-key="new-encryption-key" \
  storage-password="new-db-password" \
  smtp-password="smtp-password" \
  authentication-backend-ldap-password="new-ldap-password"
```

The CronJobs will automatically sync the new secrets within 5 minutes.

## Monitoring

Check the status of secret synchronization:

```bash
# Check LLDAP sync jobs
kubectl -n lldap get cronjobs
kubectl -n lldap get jobs

# Check Authelia sync jobs
kubectl -n authelia get cronjobs
kubectl -n authelia get jobs

# View logs of the last sync
kubectl -n lldap logs -l job-name=vault-sync-lldap-secrets-<id>
kubectl -n authelia logs -l job-name=vault-sync-authelia-secrets-<id>
```

## Troubleshooting

1. **Sync job failing**: Check that Vault is unsealed and the Kubernetes auth is properly configured.

2. **Authentication errors**: Verify the service accounts and Vault roles are correctly configured:
   ```bash
   vault read auth/kubernetes/role/lldap
   vault read auth/kubernetes/role/authelia
   ```

3. **Secret not updating**: Check the CronJob logs and ensure the Vault paths are correct.

## Security Notes

- Never commit actual secrets to Git
- The initial secrets in `secrets.yaml` files should be considered placeholders
- Always use strong, randomly generated secrets in production
- Regularly rotate secrets by updating them in Vault
- Monitor access logs in Vault for security auditing