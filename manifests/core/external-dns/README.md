# External-DNS with OVH Provider

This deployment configures [external-dns](https://github.com/kubernetes-sigs/external-dns) to automatically manage DNS records in OVH based on Kubernetes resources.

## Overview

External-DNS monitors Kubernetes Services and Ingresses and automatically creates/updates/deletes DNS records in OVH DNS.

## Configuration

### OVH Credentials

External-DNS uses the same OVH API credentials as cert-manager, stored in Vault at `secret/ovh-dns`:
- `OVH_APPLICATION_KEY`
- `OVH_APPLICATION_SECRET`
- `OVH_CONSUMER_KEY`

These credentials are synced from Vault using External Secrets Operator.

### Managed Domain

External-DNS is configured to manage records for `daddyshome.fr`.

### Record Creation

External-DNS **automatically** creates DNS records for:

1. **All Ingresses** with hosts ending in `.daddyshome.fr`
2. **All Services** of type LoadBalancer with appropriate annotations

**No manual annotation required!** All subdomains of `daddyshome.fr` are automatically managed.

### Excluding Resources

To prevent external-dns from managing specific resources, add:
```yaml
metadata:
  annotations:
    external-dns.alpha.kubernetes.io/ignore: "true"
```

### Advanced Control

For specific DNS configurations, you can still use annotations:
```yaml
metadata:
  annotations:
    # Override the hostname
    external-dns.alpha.kubernetes.io/hostname: custom.daddyshome.fr
    # Set TTL (time-to-live)
    external-dns.alpha.kubernetes.io/ttl: "300"
    # Target specific IPs (useful for services)
    external-dns.alpha.kubernetes.io/target: "192.168.1.100"
```

### TXT Registry

External-DNS uses TXT records to track ownership of DNS records. Records are prefixed with `_external-dns.` to avoid conflicts.

## Initial Setup

1. Ensure OVH credentials exist in Vault at `secret/ovh-dns`
2. Deploy using ArgoCD
3. Monitor logs for successful synchronization:
   ```bash
   kubectl logs -n external-dns deployment/external-dns
   ```

## Usage Example

To create a DNS record for a service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
  annotations:
    external-dns.alpha.kubernetes.io/hostname: my-app.daddyshome.fr
spec:
  type: LoadBalancer
  # ... rest of service spec
```

External-DNS will automatically create an A record pointing to the LoadBalancer's external IP.

## Future Scalability

The current configuration is designed to scale:

### Adding New Domains
Simply add to the `domainFilters` in `values.yaml`:
```yaml
domainFilters:
  - daddyshome.fr
  - newdomain.com
```

### Multi-Environment Strategy
For staging/production separation in the future:
```yaml
# Option 1: Use different subdomains
excludeDomains:
  - staging.daddyshome.fr  # Managed by a different external-dns instance

# Option 2: Use regex filters
regexDomainFilter: "^([a-z0-9-]+\\.)*(prod|www)\\.daddyshome\\.fr$"
```

### Migration Path
1. Set `dryRun: true` to test changes
2. Review logs for planned changes
3. Set `dryRun: false` to apply
4. Monitor with: `kubectl logs -n external-dns deployment/external-dns -f`