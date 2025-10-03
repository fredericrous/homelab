# Infrastructure Controllers

This directory contains the core infrastructure components deployed via FluxCD.

## Bootstrap Requirements

Before FluxCD can deploy Vault, you need to bootstrap the transit token secret:

```bash
# Get the transit token from your NAS Vault (or generate one)
# The token was created by: task nas:vault-transit-setup

# Bootstrap the secret
./scripts/bootstrap-vault-transit-secret.sh <VAULT_TRANSIT_TOKEN>
```

## Dependencies

1. **Reflector** - Must be deployed first to reflect secrets between namespaces
2. **MetalLB** - Provides LoadBalancer IPs
3. **Rook-Ceph** - Provides persistent storage
4. **Vault** - Depends on Reflector for transit token secret reflection
5. **Vault Transit Unseal Operator** - Manages Vault initialization and unsealing

## How it Works

1. The `vault-transit-token` secret is created manually in the `vault` namespace
2. Reflector automatically copies it to `flux-system` namespace
3. The Flux Kustomization uses `postBuild.substituteFrom` to inject the token into Vault's configuration
4. Vault starts with the transit seal configuration
5. The vault-transit-unseal-operator initializes and unseals Vault automatically