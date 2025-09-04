# Let's Encrypt SSL Certificates Setup

## Overview
SSL certificates are automatically managed by cert-manager using Let's Encrypt with OVH DNS-01 challenges.

## OVH DNS-01 Webhook Configuration

### Components
- **Webhook**: cert-manager-webhook-ovh v0.7.5
- **ClusterIssuer**: letsencrypt-ovh-webhook
- **OVH Credentials**: Stored in secret `ovh-credentials` in cert-manager namespace

### How it Works
1. **cert-manager** watches for Ingress resources with the annotation `cert-manager.io/cluster-issuer`
2. When found, it creates a Certificate resource
3. cert-manager uses the OVH webhook to create DNS TXT records for DNS-01 challenge
4. Let's Encrypt validates the DNS record and issues the certificate
5. The certificate is stored in a Kubernetes secret
6. HAProxy Ingress uses this secret for TLS termination

## Important Notes
- Certificates are automatically renewed 30 days before expiration
- HTTP (port 30080) automatically redirects to HTTPS (port 30443)
- DNS-01 challenges work without exposing services to the internet
- OVH API credentials must have DNS zone write permissions

## Adding SSL to New Services
Add these annotations and TLS section to your Ingress:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-ovh-webhook"
    haproxy.org/ssl-redirect: "true"
spec:
  tls:
  - hosts:
    - your-service.daddyshome.fr
    secretName: your-service-tls
```

## Troubleshooting
Check certificate status:
```bash
kubectl get certificate -A
kubectl describe certificate <cert-name> -n <namespace>
```

Check cert-manager logs:
```bash
kubectl logs -n cert-manager deployment/cert-manager
```

## Using Staging Environment
For testing, create a staging ClusterIssuer with the same configuration but pointing to:
`server: https://acme-staging-v02.api.letsencrypt.org/directory`

## Configuration Files
- `ovh-credentials-secret.yaml`: OVH API credentials secret
- `clusterissuer-letsencrypt-ovh-webhook.yaml`: Production ClusterIssuer
- `webhook-ovh-manifests.yaml`: OVH webhook deployment (generated from Helm)
