# External Secrets Operator Configuration

This directory contains the configuration for External Secrets Operator (ESO) to work with Vault.

## Key Components

1. **vault-token-reader-rbac.yaml**: Provides RBAC permissions for the ESO configuration job to read the vault-admin-token from the vault namespace. This eliminates the need for manual secret copying.

2. **job-vault-configure-eso.yaml**: Automatically configures Vault authentication for ESO. The job:
   - Uses a dedicated service account with permissions to read vault-admin-token from vault namespace
   - Dynamically fetches the token using the Kubernetes API
   - Configures Vault's Kubernetes auth method for ESO
   - Is idempotent - safe to run multiple times

3. **cluster-secret-store.yaml**: Defines the main ClusterSecretStore for accessing secrets in Vault

4. **clustersecretstore-nas-vault.yaml**: ClusterSecretStore for accessing the NAS Vault (used for PKI)

## GitOps Compliance

The configuration is fully GitOps compliant:
- No manual secret copying required
- All configurations are declarative
- Jobs are idempotent and can be safely re-run
- RBAC ensures proper access control across namespaces

When the cluster is destroyed and recreated, ArgoCD will:
1. Deploy ESO via Helm
2. Create the necessary RBAC
3. Run the configuration job which fetches the vault token automatically
4. Configure Vault authentication for ESO

No manual intervention is required.