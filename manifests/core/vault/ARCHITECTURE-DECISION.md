# Vault Architecture Decision

## Current Architecture
- **vault** app: Core Vault deployment
- **vault-config** app: Configuration workflows (separate app)

## Why We Chose This
1. **PostSync Hook Deadlock**: Terraform waits for sync completion, but PostSync hooks prevent completion
2. **CRD Dependencies**: Workflows need Argo Workflow CRDs from another app

## Better Alternatives Considered

### Option 1: Sync Hooks (Not PostSync)
```yaml
annotations:
  argocd.argoproj.io/hook: Sync
  argocd.argoproj.io/hook-delete-policy: HookSucceeded
```
**Pros**: Runs during sync, not after
**Cons**: Still blocks sync status, needs CRDs

### Option 2: Jobs with Sync Waves
```yaml
annotations:
  argocd.argoproj.io/sync-wave: "10"
```
**Pros**: Clean, no hooks, proper ordering
**Cons**: Jobs might run before Vault is ready

### Option 3: Init Containers
```yaml
initContainers:
- name: configure-vault
  image: vault:latest
```
**Pros**: Runs at pod startup, guaranteed ordering
**Cons**: Complex for multi-step configuration

### Option 4: Vault Operator
Use HashiCorp or Bank-Vaults operator
**Pros**: Handles full lifecycle
**Cons**: Another operator to manage

## Recommendation
For new deployments, use **Jobs with sync waves** and proper readiness checks. The separate app approach works but adds complexity.

## Migration Path
1. Keep current architecture (it works)
2. If refactoring, convert to sync waves with readiness gates
3. Consider operator for production use