# Cert-Manager Setup with OVH DNS-01

This setup provides automatic SSL certificate management using Let's Encrypt with OVH DNS-01 challenges.

## Components

1. **cert-manager v1.16.2** - Core certificate management
2. **cert-manager-webhook-ovh** - OVH DNS provider for DNS-01 challenges
3. **Leader election fixes** - Required for Talos (no kube-system access)
4. **Credential distribution** - Job to copy OVH credentials to all namespaces

## Why These Files Are Needed

- `webhook-ovh-manifests.yaml` - The OVH webhook deployment (generated from Helm)
- `ovh-credentials-secret.yaml` - OVH API credentials (applicationKey, applicationSecret, consumerKey)
- `ovh-webhook-rbac-fix.yaml` - RBAC to allow webhook to read the ovh-credentials secret
- `ovh-credentials-copy-job.yaml` - Copies credentials to all namespaces (webhook limitation - it looks for secrets in the same namespace as the Certificate)
- `clusterissuer-letsencrypt-ovh-webhook-final.yaml` - ClusterIssuer for Let's Encrypt
- `cainjector-leader-election-fix.yaml` & `cert-manager-leader-election-fix.yaml` - Fix leader election to use cert-manager namespace instead of kube-system
- `cainjector-patch.yaml` & `cert-manager-controller-patch.yaml` - Patches to change leader election namespace

## Deployment

```bash
# From the homelab root directory
kustomize build manifests/cert-manager | kubectl apply -f -

# Or using kubectl directly
kubectl apply -k manifests/cert-manager/
```

## Verify Installation

```bash
# Check pods are running
kubectl get pods -n cert-manager

# Check ClusterIssuer is ready
kubectl get clusterissuer

# Check if certificates are being issued
kubectl get certificate -A
kubectl get challenges -A
```

## Troubleshooting

If certificates are not being issued:

1. Check cert-manager logs: `kubectl logs -n cert-manager deployment/cert-manager`
2. Check webhook logs: `kubectl logs -n cert-manager -l app=cert-manager-webhook-ovh`
3. Check challenge status: `kubectl describe challenge -n <namespace> <challenge-name>`
4. Ensure OVH credentials are in the target namespace: `kubectl get secret -n <namespace> ovh-credentials`

## OVH API Credentials

The OVH API credentials need the following permissions:
- GET /domain/zone/*
- PUT /domain/zone/*
- POST /domain/zone/*
- DELETE /domain/zone/*

Create them at: https://api.ovh.com/createToken/