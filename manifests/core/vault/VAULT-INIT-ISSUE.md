# Vault Initialization Issue

## Problem
Vault 1.17.x versions have a bug where the file storage backend incorrectly reports as "already initialized" even when it's not properly initialized. This creates a deadlock in our GitOps deployment.

## Root Cause
Based on multiple GitHub issues (#28684, #28530, #29056), there appears to be a regression in Vault 1.17.x where:
1. The file storage backend incorrectly detects initialization state
2. `vault operator init -status` reports "Vault is initialized" when it's not
3. The vault-init job detects this false initialization and fails
4. No vault-admin-token secret is created
5. All dependent jobs wait forever

This particularly affects:
- Fresh deployments with empty file storage
- Upgrades from older versions (especially 1.14 to 1.17)
- Migration scenarios

Note: This is NOT caused by persistent storage retention - the user's deploy.sh script completely wipes Talos nodes and disks.

## Solutions

### Option 1: Downgrade to Vault 1.16.x or 1.14.x
Use a version before the regression was introduced:
```yaml
image: hashicorp/vault:1.16.3  # or 1.14.10
```

### Option 2: Use Raft Storage Instead of File Storage
Switch to integrated storage which doesn't have this bug:
```hcl
storage "raft" {
  path = "/vault/data"
  node_id = "vault-0"
}
```

### Option 3: Wait for Bug Fix
Monitor GitHub issues for a fix:
- [Issue #28684](https://github.com/hashicorp/vault/issues/28684)
- [Issue #28530](https://github.com/hashicorp/vault/issues/28530)
- [Issue #29056](https://github.com/hashicorp/vault/issues/29056)

### Option 4: Use Vault Helm Chart
The official Helm chart may have workarounds or better initialization handling:

```yaml
helmCharts:
- name: vault
  repo: https://helm.releases.hashicorp.com
  version: 0.28.1
  namespace: vault
  releaseName: vault
  valuesInline:
    server:
      dataStorage:
        enabled: true
        size: 10Gi
        storageClass: rook-ceph-block
```

## Current Status
The issue is a known bug in Vault 1.17.x where file storage incorrectly reports as initialized. There is no `disable_auto_init` parameter for file storage backend - that was an incorrect assumption.

## Additional Notes
- The init-vault.sh script is already idempotent and handles recovery scenarios
- Placeholder secrets were created as a temporary workaround but can be removed once Vault properly initializes
- The terraform sync-vault.sh script detects and reports the auto-initialization issue