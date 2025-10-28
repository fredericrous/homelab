# Homelab Platform

This repository codifies my homelab clusters (``nas`` and ``homelab``) with FluxCD, Istio multi-primary and Vault integration. The new bootstrap CLI builds everything end-to-end without manual secret copy or node-port hacks.

## Zero-Touch Bootstrap

```bash
go build ./cmd/bootstrap
./bootstrap nas install
./bootstrap homelab install
./bootstrap verify
```

The first two commands stand up each cluster, reconcile Flux, provision Istio east-west gateways (with SDS certs) and synchronise remote secrets. Between runs, hand-off data (kubeconfigs, remote secret payloads, gateway certs, transit tokens) is persisted in `.env.generated`; this file is git-ignored and should travel with the repo between the ``nas`` and ``homelab`` steps.

## Verify the Mesh

`./bootstrap verify` runs the acceptance checks automatically, but the relevant manual commands are:

```bash
# Flux state
flux --kubeconfig infrastructure/nas/kubeconfig.yaml get ks -A
flux --kubeconfig infrastructure/homelab/kubeconfig.yaml get ks -A

# Istio control planes and gateways
kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml -n istio-system get deploy istiod istio-eastwestgateway
kubectl --kubeconfig infrastructure/homelab/kubeconfig.yaml -n istio-system get deploy istiod istio-eastwestgateway

# Cross-cluster discovery secrets
kubectl --kubeconfig infrastructure/homelab/kubeconfig.yaml -n istio-system get secret istio-remote-secret-nas
kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml -n istio-system get secret istio-remote-secret-homelab

# Vault over the mesh (uses the shared SDS cert mounted by the job)
kubectl --kubeconfig infrastructure/homelab/kubeconfig.yaml -n vault exec deploy/vault-vault -- \
  curl -sf --cacert /mesh/ca/root-cert.pem https://vault.vault.svc.cluster.local:8200/v1/sys/health
```

Successful runs show ``READY`` deployments, both remote-secret Secrets present, and the Vault health endpoint returning ``{\"initialized\":true,...}`` over HTTPS via the east-west gateway.

## Troubleshooting Cheatsheet

- `./bootstrap nas install` writes the NAS kubeconfig and generated mesh material to `.env.generated`; if that file is missing on the homelab run, the installer stops after the remote-secret step.
- `./bootstrap verify` surfaces trimmed `istioctl proxy-status` output; rerun after watching `kubectl -n istio-system get pods` if proxies are recycling.
- The NAS east-west gateway image pull failures generally indicate the SDS secret is absent—check `kubectl -n istio-system get secret istio-eastwestgateway-certs` on both clusters.
- Vault PKI sync uses the token stored at `secret/nas/vault-token`; if the CronJob has not refreshed it yet, the PKI job exits with `Failed to load NAS Vault token`.

## Legacy Notes

Old ArgoCD/bootstrap scripts are kept under `docs/` for historical context, but the supported flow is the four commands above.
