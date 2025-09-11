# Vault Transit Unseal Operator

This operator manages automatic unsealing of Vault instances using Transit unseal.

## Overview

The Vault Transit Unseal operator watches for Vault pods and automatically:
1. Initializes new Vault instances with Transit unseal backend
2. Unseals Vault instances using the Transit backend  
3. Creates and stores recovery keys and admin token as Kubernetes secrets
4. Optionally configures post-unseal settings (KV engine, External Secrets Operator)

## Deployment

This deployment uses the official Helm chart from https://fredericrous.github.io/charts/

```bash
kubectl apply -k .
```

## Configuration

The operator is deployed via Helm with the following configuration:

- **Chart Version**: 1.0.0
- **Image Version**: 1.0.5 (latest with command-line flags support)
- **Watch Namespace**: All namespaces (empty string)
- **Leader Election**: Disabled (single replica deployment)
- **Max Concurrent Reconciles**: 3
- **Webhook**: Disabled (not needed for basic functionality)

### Transit Vault Token

The operator needs a token from the Transit Vault (QNAP NAS at 192.168.1.42:61200) to perform unseal operations. This token should be stored in the `vault-transit-token` secret in the vault namespace.

### CRD

The operator uses a custom resource `VaultTransitUnseal` to configure how Vault instances should be managed. The CRD is automatically installed by the Helm chart from the `crds/` directory.

See `/manifests/core/vault/vault-transit-unseal.yaml` for the VaultTransitUnseal configuration.

## Features

1. **Automatic Vault Initialization** with transit unseal
2. **Post-Unseal Configuration** (configured in VaultTransitUnseal resource):
   - Enables KV v2 engine at `/secret`
   - Configures Kubernetes auth
   - Sets up External Secrets Operator (ESO) access
3. **CRD Management**: Helm automatically installs/updates CRDs from the chart

## Troubleshooting

Check operator logs:
```bash
kubectl logs -n vault-transit-unseal-operator deployment/vault-transit-unseal-operator
```

Check if the operator is running:
```bash
kubectl get pods -n vault-transit-unseal-operator
```

Check VaultTransitUnseal resources:
```bash
kubectl get vaulttransitunseals -A
```

Verify CRD is installed:
```bash
kubectl get crd vaulttransitunseals.vault.homelab.io
```

## Upgrading

To upgrade the operator, update the `image.tag` in the kustomization.yaml and reapply:

```yaml
valuesInline:
  image:
    tag: "NEW_VERSION"
```

To upgrade the Helm chart itself:
```yaml
helmCharts:
- name: vault-transit-unseal-operator
  version: "NEW_CHART_VERSION"
```

## Migration from Kustomize

This deployment has been migrated from a pure Kustomize approach to Helm for better version management and automated releases. The old Kustomize files (deployment.yaml, rbac.yaml, etc.) have been removed in favor of the Helm chart.