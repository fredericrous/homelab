# Istio Shared CA Setup

This document describes the automated Istio CA setup that enables a shared trust anchor between the homelab and NAS clusters for east-west traffic and remote injection.

## Architecture Overview

1. **CA Generation**: A Kubernetes Job generates the Istio root certificates and stores them in Vault
2. **Distribution**: ExternalSecrets on both clusters pull the CA from Vault to create the `cacerts` secret
3. **Service Mesh**: Istio uses the shared CA for mTLS between clusters
4. **Vault Access**: NAS accesses homelab Vault through the Istio service mesh (no more direct IP access)

## Components Created

### Homelab Cluster

- `kubernetes/homelab/platform-foundation/istio/ca-setup/`
  - `istio-ca-generation-job.yaml` - Job that generates the CA
  - `istio-ca-externalsecret.yaml` - ExternalSecret to create cacerts
  - `kustomization.yaml` - Kustomize configuration
- `kubernetes/homelab/platform-foundation/istio/ca-setup-kustomization.yaml` - Flux Kustomization
- `kubernetes/homelab/platform-foundation/istio/expose-vault-nas.yaml` - Exposes Vault via Istio

### NAS Cluster  

- `kubernetes/nas/platform-foundation/istio/ca-setup/`
  - `vault-secret-store.yaml` - SecretStore to connect to homelab Vault
  - `istio-ca-externalsecret.yaml` - ExternalSecret to create cacerts
  - `kustomization.yaml` - Kustomize configuration
- `kubernetes/nas/platform-foundation/istio/ca-setup-kustomization.yaml` - Flux Kustomization

### Changes Made

1. **Updated NAS Istiod configuration** (`kubernetes/nas/platform-foundation/istio/istiod.yaml`):
   - Changed `injectionURL` from hardcoded IP to `https://istio-eastwestgateway.istio-system.svc:15443/inject`

2. **Fixed NAS east-west gateway** (`kubernetes/nas/platform-foundation/istio/istio-eastwest-gateway.yaml`):
   - Added proper dependencies on `istio-base` and `istiod`

3. **Replaced hardcoded Vault addresses** (192.168.1.42:61200 → vault-vault-nas.vault.svc.cluster.local:8200):
   - `kubernetes/homelab/security/configs/vault-config-operator/pki-intermediate-ca.yaml`
   - `kubernetes/homelab/platform-foundation/configs/nas-integration/nas-token-external-secret.yaml`
   - `kubernetes/homelab/platform-foundation/configs/nas-integration/nas-token-broker-cronjob.yaml`
   - `kubernetes/homelab/monitoring/configs/nas-integration-monitoring.yaml`

## Deployment Instructions

### Prerequisites

1. Ensure Vault is running on homelab cluster
2. Ensure External Secrets Operator is installed on both clusters
3. Ensure proper Vault tokens are available

### Step 1: Deploy CA Setup on Homelab

```bash
# Apply the CA setup Kustomization
kubectl --kubeconfig kubeconfig apply -f kubernetes/homelab/platform-foundation/istio/ca-setup-kustomization.yaml

# Wait for the job to complete
kubectl --kubeconfig kubeconfig -n istio-system wait --for=condition=complete job/istio-ca-setup --timeout=5m

# Verify the CA was created
kubectl --kubeconfig kubeconfig -n istio-system get secret cacerts
```

### Step 2: Update Vault Token for NAS

The NAS cluster needs a Vault token to access the homelab Vault. Update the token in the NAS SecretStore:

```bash
# Get or create a Vault token with read access to secret/istio/ca
VAULT_TOKEN="your-vault-token-here"

# Create the secret on NAS cluster
kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml -n istio-system \
  create secret generic vault-token-homelab \
  --from-literal=token="$VAULT_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Step 3: Deploy CA Setup on NAS

```bash
# Apply the CA setup Kustomization
kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml apply -f kubernetes/nas/platform-foundation/istio/ca-setup-kustomization.yaml

# Wait for the ExternalSecret to sync
kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml -n istio-system wait --for=condition=SecretSynced externalsecret/istio-cacerts --timeout=2m

# Verify the CA was synced
kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml -n istio-system get secret cacerts
```

### Step 4: Reconcile Istio Components

```bash
# Reconcile homelab Istio
flux --kubeconfig kubeconfig reconcile helmrelease istio-base -n flux-system
flux --kubeconfig kubeconfig reconcile helmrelease istiod -n flux-system
flux --kubeconfig kubeconfig reconcile helmrelease istio-eastwestgateway -n flux-system

# Reconcile NAS Istio
flux --kubeconfig infrastructure/nas/kubeconfig.yaml reconcile helmrelease istio-base -n flux-system
flux --kubeconfig infrastructure/nas/kubeconfig.yaml reconcile helmrelease istiod -n flux-system
flux --kubeconfig infrastructure/nas/kubeconfig.yaml reconcile helmrelease istio-eastwestgateway -n flux-system
```

### Step 5: Verify the Setup

Run the provided test script:

```bash
./kubernetes/homelab/platform-foundation/istio/test-istio-ca-setup.sh
```

## Manual CA Regeneration

If you need to regenerate the CA (e.g., for rotation):

```bash
# Delete the existing CA from Vault
vault kv delete secret/istio/ca

# Delete the job
kubectl --kubeconfig kubeconfig -n istio-system delete job istio-ca-setup

# Reapply the CA setup to regenerate
kubectl --kubeconfig kubeconfig apply -f kubernetes/homelab/platform-foundation/istio/ca-setup/

# The ExternalSecrets will automatically pick up the new CA
```

## Troubleshooting

### CA Not Syncing to NAS

1. Check the Vault token is valid:
   ```bash
   kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml -n istio-system get secret vault-token-homelab
   ```

2. Check ExternalSecret status:
   ```bash
   kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml -n istio-system describe externalsecret istio-cacerts
   ```

3. Check SecretStore connectivity:
   ```bash
   kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml -n istio-system describe secretstore vault-backend-homelab
   ```

### East-West Gateway Not Starting

1. Ensure cacerts secret exists before the gateway starts
2. Check the gateway pod logs:
   ```bash
   kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml -n istio-system logs -l app=istio-eastwestgateway
   ```

### Injection Not Working

1. Verify the webhook is configured:
   ```bash
   kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml get mutatingwebhookconfigurations
   ```

2. Test injection with a dry-run:
   ```bash
   kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml -n default run test --image=nginx --dry-run=server -o yaml | grep istio
   ```

## GitOps Integration

The CA setup is fully integrated with Flux GitOps. The dependency chain is:

1. `vault` → `external-secrets` → `istio-ca-setup` → `istio-base` → `istiod` → `istio-eastwestgateway`

This ensures proper ordering and that the shared CA is in place before any Istio components start.