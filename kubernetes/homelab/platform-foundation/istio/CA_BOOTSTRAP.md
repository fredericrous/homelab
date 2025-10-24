# Istio Root CA Bootstrap (Homelab <-> NAS)

This folder contains the automation for bootstrapping and distributing a shared Istio CA from the homelab Vault so that both the homelab and NAS clusters share a common trust anchor for mTLS communication and remote injection. The high‑level approach:

1. **Homelab bootstrap job (`istio-ca-bootstrap`)**
   * Runs as a Kubernetes `Job` in the homelab cluster with service account `istio-ca-bootstrap`.
   * Uses the Vault Kubernetes auth role `istio-ca-bootstrap` to obtain a client token.
   * Checks for `secret/data/istio/ca`; if missing, generates a new 4096-bit RSA root certificate bundle (`root-cert.pem`, `cert-chain.pem`, `key.pem`) valid for 10 years and writes it to Vault. Subsequent runs become a no‑op (idempotent).
2. **Homelab ExternalSecret (`istio-system/istio-cacerts`)**
   * Reads the PEM objects from `secret/istio/ca` and writes a secret named `cacerts` with the exact filenames Istio expects.
3. **NAS sync (`kubernetes/nas/platform-foundation/istio/istio-ca-sync.yaml`)**
   * Creates a `SecretStore` that points at the homelab Vault via the Istio service mesh (`vault-vault-nas.vault.svc.cluster.local:8200`).
   * Uses Kubernetes auth role `istio-ca-sync` to authenticate from NAS cluster.
   * Mirrors the same PEM files into the NAS `istio-system` namespace as secret `cacerts`.
4. **Flux dependencies**
   * The `istio-ca-bootstrap` Kustomization depends on the `vault` HelmRelease.
   * The `istio-config` Kustomization depends on `istio-ca-bootstrap` and `external-secrets`.
   * This ensures the CA exists before any Istio components are deployed.

## Vault Prerequisites

### 1. Create the Vault Policy

Create a policy file `istio-ca-policy.hcl`:

```hcl
# Policy for Istio CA bootstrap job (write access)
path "secret/data/istio/ca" {
  capabilities = ["create", "read", "update", "patch"]
}

# Policy for Istio CA sync (read-only access)  
path "secret/data/istio/ca" {
  capabilities = ["read"]
}
```

Apply the policy:

```bash
vault policy write istio-ca-bootstrap istio-ca-policy.hcl
vault policy write istio-ca-sync istio-ca-policy.hcl
```

### 2. Configure Kubernetes Auth Roles

Enable Kubernetes auth if not already enabled:

```bash
vault auth enable kubernetes
```

Create the auth roles for both clusters:

```bash
# Role for homelab bootstrap job
vault write auth/kubernetes/role/istio-ca-bootstrap \
  bound_service_account_names=istio-ca-bootstrap \
  bound_service_account_namespaces=istio-system \
  policies=istio-ca-bootstrap \
  ttl=1h

# Role for NAS sync (needs to authenticate from NAS cluster)
vault write auth/kubernetes/role/istio-ca-sync \
  bound_service_account_names=istio-ca-sync \
  bound_service_account_namespaces=istio-system \
  policies=istio-ca-sync \
  ttl=24h
```

## Deployment Steps

The Flux GitOps automation handles the deployment order, but for manual deployment:

### 1. Deploy on Homelab Cluster

```bash
# Apply the CA bootstrap job
kubectl --kubeconfig kubeconfig apply -f kubernetes/homelab/platform-foundation/istio/ca-bootstrap-kustomization.yaml

# Wait for the job to complete
kubectl --kubeconfig kubeconfig -n istio-system wait --for=condition=complete job/istio-ca-bootstrap --timeout=5m

# Verify the secret was created
kubectl --kubeconfig kubeconfig -n istio-system get secret cacerts
```

### 2. Deploy on NAS Cluster

```bash
# Apply the Istio configuration (includes CA sync)
kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml apply -k kubernetes/nas/platform-foundation/istio/

# Verify the secret was synced
kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml -n istio-system get secret cacerts
```

### 3. Verify CA Consistency

```bash
# Compare CA fingerprints between clusters
HOMELAB_CA=$(kubectl --kubeconfig kubeconfig -n istio-system get secret cacerts -o jsonpath='{.data.root-cert\.pem}' | base64 -d | openssl x509 -fingerprint -noout)
NAS_CA=$(kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml -n istio-system get secret cacerts -o jsonpath='{.data.root-cert\.pem}' | base64 -d | openssl x509 -fingerprint -noout)

echo "Homelab CA: $HOMELAB_CA"
echo "NAS CA:     $NAS_CA"
```

### 4. Reconcile Istio Components

```bash
# Reconcile Istio deployments
flux --kubeconfig kubeconfig reconcile helmrelease istio-base -n flux-system
flux --kubeconfig kubeconfig reconcile helmrelease istiod -n flux-system
flux --kubeconfig infrastructure/nas/kubeconfig.yaml reconcile helmrelease istio-eastwestgateway -n flux-system
```

## Troubleshooting

### CA Bootstrap Job Failed

Check the job logs:
```bash
kubectl --kubeconfig kubeconfig -n istio-system logs job/istio-ca-bootstrap
```

Common issues:
- Vault not ready or unreachable
- Kubernetes auth not configured properly
- Missing permissions on Vault policy

### ExternalSecret Not Syncing

Check the ExternalSecret status:
```bash
kubectl --kubeconfig kubeconfig -n istio-system describe externalsecret istio-cacerts
```

### NAS Can't Access Homelab Vault

Ensure the ServiceEntry for Vault is applied:
```bash
kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml -n vault get serviceentry vault-vault-nas
```

Check if the east-west gateway is running:
```bash
kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml -n istio-system get pods -l app=istio-eastwestgateway
```
