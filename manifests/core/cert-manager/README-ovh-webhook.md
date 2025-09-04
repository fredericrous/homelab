# OVH Webhook Configuration for cert-manager

## Issue with webhook v0.3.2

The `baarde/cert-manager-webhook-ovh:0.3.2` has a limitation where it only supports reading the `applicationSecret` from a Kubernetes secret reference, but NOT `applicationKey` and `consumerKey`.

This means we cannot use the fully secure approach of storing all credentials in secrets as shown in `clusterissuer-letsencrypt-ovh-webhook-secure.yaml`.

## Current Solution

We use a Kustomize patch (`patch-clusterissuer-ovh-credentials.yaml`) to override the ClusterIssuer configuration with direct values for `applicationKey` and `consumerKey`, while keeping the secret reference for `applicationSecret`.

## Future Improvements

1. **Upgrade webhook version**: Check if newer versions support all credential references
2. **Fork and patch webhook**: Add support for missing credential references
3. **Use cert-manager external provider**: Consider using the official cert-manager external DNS providers
4. **Implement Kustomize replacements**: Use Kustomize variable substitution to inject credentials at build time from environment variables

## Security Considerations

While `applicationKey` and `consumerKey` are in the ClusterIssuer manifest, the most sensitive credential (`applicationSecret`) is still stored in a Kubernetes secret. The exposed credentials alone cannot perform API operations without the secret.

## Files

- `clusterissuer-letsencrypt-ovh-webhook-secure.yaml`: Ideal configuration (doesn't work with v0.3.2)
- `clusterissuer-letsencrypt-ovh-webhook-final.yaml`: Old approach with placeholders (deprecated)
- `patch-clusterissuer-ovh-credentials.yaml`: Current solution patch