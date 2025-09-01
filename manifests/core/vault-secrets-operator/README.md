# Vault Secrets Operator (VSO)

This directory contains the Vault Secrets Operator deployment and configuration.

## Sync Wave Ordering

VSO deployment uses ArgoCD sync waves to ensure proper installation order:

1. **Wave -10**: Helm chart installation (includes CRDs and operator deployment)
   - All Helm resources get `argocd.argoproj.io/sync-wave: "-10"` via `commonAnnotations`
   - This ensures CRDs are installed before any custom resources

2. **Wave 10**: VSO custom resources (VaultAuth, VaultStaticSecret, etc.)
   - All `secrets.hashicorp.com` resources get sync-wave 10
   - These depend on CRDs from wave -10

3. **Wave 20**: Configuration jobs
   - Jobs that configure Vault for VSO run after VSO is ready

## Why This Pattern?

Without sync waves, ArgoCD tries to create all resources simultaneously, causing:
- "CRD not found" errors for VSO custom resources
- Sync failures requiring manual intervention

The sync wave pattern ensures reliable deployment from scratch.

## Troubleshooting

If sync fails with CRD errors:
1. Check if wave -10 completed: `kubectl get crd | grep secrets.hashicorp.com`
2. Verify Helm is enabled in ArgoCD: `kubectl get cm argocd-cm -n argocd -o yaml | grep buildOptions`
3. Force refresh: `kubectl patch app -n argocd vault-secrets-operator --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"true"}}}'`

## Resources

- **VaultAuth**: Configures how VSO authenticates to Vault
- **VaultAuthGlobal**: Default auth method for all namespaces
- **VaultStaticSecret**: Syncs static secrets from Vault to K8s secrets
- **Jobs**: Configure Vault policies and auth methods for VSO