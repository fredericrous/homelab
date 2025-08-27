# ArgoCD Self-Management Configuration

This directory contains ArgoCD's own configuration, managed by ArgoCD itself following the GitOps self-management pattern.

## Why Self-Management?

1. **Dependency Management**: Some ArgoCD configurations depend on CRDs from other operators (like Vault Secrets Operator)
2. **GitOps Consistency**: All configuration is managed the same way - through Git
3. **Sync Waves**: Ensures proper ordering - this deploys after VSO and other dependencies

## What's Managed Here?

- **Vault Integration**: 
  - `vault-auth.yaml` - VaultAuth resource for ArgoCD to authenticate with Vault
  - `argocd-ldap-secret.yaml` - VaultStaticSecret to pull LDAP credentials from Vault

## Sync Wave

This application has `syncWave: "10"` which means it deploys after:
- Vault (`syncWave: "-16"`)
- Vault Secrets Operator (`syncWave: "-15"`)
- Other core infrastructure

This ensures all required CRDs and services are available before ArgoCD tries to configure itself.

## Adding More Configuration

Any ArgoCD configuration that should be managed by GitOps can be added here:
- ConfigMap patches
- RBAC policies
- Repository credentials
- Notification configurations
- etc.