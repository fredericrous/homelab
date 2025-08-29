# Vault Initialization Issue

## Problem
Vault 1.17.0-1.17.6 has a security vulnerability (CVE-2024-8185) that causes it to auto-initialize when using file storage backend, creating inaccessible keys that cannot be recovered.

## Root Cause
CVE-2024-8185: A security vulnerability in Vault versions 1.17.0 through 1.17.6 where file storage backend auto-initializes by default, creating encryption keys that are not accessible to operators. This creates a deadlock where:
1. Vault auto-initializes on startup with unknown keys
2. The vault-init job detects initialization and fails (correctly)
3. No vault-admin-token secret is created
4. All dependent jobs wait forever

Note: This is NOT caused by persistent storage - the user's deploy.sh script wipes Talos nodes and disks completely.

## Solutions

### Option 1: Fix the Configuration (Implemented)
Add `disable_auto_init = true` to the file storage configuration in vault.hcl:

```hcl
storage "file" {
  path = "/vault/data"
  disable_auto_init = true  # Fix for CVE-2024-8185
}
```

### Option 2: Upgrade Vault Version
Upgrade to Vault 1.17.1 or later where this vulnerability is fixed:
- 1.17.1 fixes CVE-2024-8185
- Latest stable version recommended

### Option 3: Use Different Storage Backend
Switch from file storage to a backend not affected by CVE-2024-8185:
- Raft (built-in, recommended)
- Consul
- etcd

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
We have implemented Option 1 by adding `disable_auto_init = true` to the Vault configuration. This prevents the auto-initialization behavior in Vault 1.17.0-1.17.6.

## Additional Notes
- The init-vault.sh script is already idempotent and handles recovery scenarios
- Placeholder secrets were created as a temporary workaround but can be removed once Vault properly initializes
- The terraform sync-vault.sh script detects and reports the auto-initialization issue