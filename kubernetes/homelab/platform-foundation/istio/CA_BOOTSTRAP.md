# Istio Root CA Retrofit (Homelab <-> NAS)

This folder contains the automation for bootstrapping and distributing a shared Istio CA out of the homelab Vault so that the NAS cluster can trust the homelab control plane and vice versa. The high‑level approach:

1. **Homelab bootstrap job (`istio-ca-bootstrap`)**
   * Runs as a Kubernetes `Job` in the homelab cluster with service account `istio-ca-bootstrap`.
   * Uses the Vault Kubernetes auth role `istio-ca-bootstrap` to obtain a client token.
   * Checks for `secret/data/istio/ca`; if missing, generates a new root ECDSA certificate bundle (`root-cert.pem`, `cert-chain.pem`, `key.pem`) and writes it to Vault. Subsequent runs become a no‑op.
2. **Homelab ExternalSecret (`istio-system/istio-cacerts`)**
   * Reads the PEM objects from `secret/istio/ca` and writes a secret named `cacerts` with the exact filenames Istio expects.
3. **NAS sync (`kubernetes/nas/platform-foundation/istio/istio-ca-sync.yaml`)**
   * Creates a `SecretStore` that points at the homelab Vault (Kubernetes auth role `istio-ca-sync`) and mirrors the same PEM files into the NAS `istio-system` namespace.
4. **Istio dependencies**
   * The `istio-base` HelmRelease declares a dependency on `istio-ca-bootstrap` so the CA exists before `istiod` comes up.

### Vault prerequisites

Ensure you have a Vault policy (e.g. `istio-ca`) with at least:

```
path "secret/data/istio/ca" {
  capabilities = ["create", "read", "update", "patch"]
}
```

Create Kubernetes auth roles so the homelab and NAS service accounts can authenticate:

```
vault write auth/kubernetes/role/istio-ca-bootstrap \ 
  bound_service_account_names=istio-ca-bootstrap \ 
  bound_service_account_namespaces=istio-system \ 
  policies=istio-ca \ 
  ttl=24h

vault write auth/kubernetes/role/istio-ca-sync \ 
  bound_service_account_names=istio-ca-sync \ 
  bound_service_account_namespaces=istio-system \ 
  policies=istio-ca \ 
  ttl=24h
```

Apply the Flux overlays in this order:

```
# Homelab: bootstrap the CA and homelab Secret
kubectl apply -f kubernetes/homelab/platform-foundation/istio/ca-bootstrap-kustomization.yaml
kubectl apply -f kubernetes/homelab/security/configs/kustomization.yaml
kubectl apply -f kubernetes/homelab/platform-foundation/istio/kustomization.yaml

# NAS: mirror the CA into the remote cluster
kubectl apply -f kubernetes/nas/platform-foundation/istio/kustomization.yaml
```

Once the job has run, verify both clusters have the same `istio-system/cacerts`. Then reconcile the `istiod` and `istio-eastwestgateway` HelmReleases; the NAS gateway pods should start with a valid `istio-proxy` serving the shared root.
