# Vault Configuration Workflows

This application contains post-deployment configuration workflows for Vault.

## Why Separate from Vault?

The workflows were originally PostSync hooks in the vault app, which created a circular dependency:
- Vault sync waits for PostSync hooks to complete
- PostSync hooks (workflows) can't be created until sync completes
- Terraform waits for sync to complete, creating a deadlock

## Solution

By separating configuration into its own app with proper dependencies:
1. Vault deploys and syncs completely
2. vault-config deploys after Vault is ready
3. Workflows run as normal resources (not hooks)
4. No circular dependencies or deadlocks

## Workflows

- `workflow-configure-kv.yaml` - Enables KV v2 secret engine at `secret/`
- `workflow-configure-eso.yaml` - Configures Vault access for External Secrets Operator

## Dependencies

This app depends on:
- vault: Must be deployed and unsealed
- external-secrets-operator: For ESO configuration
- argo-workflows-crds: To run workflows