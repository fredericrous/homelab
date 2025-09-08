# Terraform Deployment Prerequisites

Before running `terraform apply`, ensure the following prerequisites are met:

## 1. Vault Transit Token Setup

### When using Taskfile (Recommended)

If you're using `task deploy` from the root directory, the transit token is automatically fetched from QNAP Vault during the prereq stage.

### When using terraform directly

If running terraform commands directly without Taskfile, you need to set up the transit token:

```bash
# Option 1: Export the token
export K8S_VAULT_TRANSIT_TOKEN="your-transit-token-here"

# Option 2: Run the setup script (will prompt for token)
./scripts/setup-transit-token.sh
```

The token can be found in CLAUDE.local.md under 'Transit Token for K8s Vault'.

## 2. Verify Core App Versions

Ensure the following versions are correct in the manifests:

- **vault-transit-unseal-operator**: v0.2.1 or later (supports adminTokenAnnotations)
  - Location: `manifests/core/vault-transit-unseal-operator/kustomization.yaml`
  - CRD must include adminTokenAnnotations field

## 3. Application Dependencies

The following sync wave order must be maintained:

1. **Cilium** (-30) - CNI must be first
2. **Kyverno** (-26) - Policy engine
3. **Argo Workflows CRDs** (-25) - Required by Rook-Ceph
4. **Rook-Ceph** (-22) - Storage provider
5. **Vault Transit Unseal Operator** (-17) - Must be before Vault
6. **Vault** (-16) - Secret management
7. **External Secrets Operator** (-15) - Secret synchronization
8. **CloudNativePG** (-12) - Database operator
9. **Argo Workflows Config** (-5) - Requires Vault, ESO, and PostgreSQL

## Troubleshooting

If the deployment fails:

1. Check pod logs for the failing application
2. Verify CRDs are installed for operators
3. Ensure sync wave dependencies are correct
4. Check that all required secrets exist