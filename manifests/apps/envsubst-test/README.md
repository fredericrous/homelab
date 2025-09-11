# ArgoCD Envsubst Plugin Test Application

This is a test application to verify the ArgoCD environment substitution plugin is working correctly.

## How it Works

1. The `.argocd-envsubst` file triggers the envsubst plugin for this directory
2. The plugin reads environment variables from the ConfigMap `argocd-env-vars` in the `argocd` namespace
3. Variables in the format `${VAR_NAME}` or `${VAR_NAME:-default}` are substituted
4. The processed manifests are then applied to the cluster

## Deployment

To deploy this test application:

```bash
kubectl apply -f app.yaml
```

Or sync it through ArgoCD UI/CLI.

## Verification

After deployment, check the ConfigMap to see if variables were substituted:

```bash
kubectl get configmap test-config -n envsubst-test -o yaml
```

You should see the actual values instead of variable placeholders.

Check the deployment:

```bash
kubectl get deployment -n envsubst-test envsubst-test -o yaml
```

The resource requests/limits should have the substituted values.

## Using the Plugin in Your Applications

To use the envsubst plugin in your own applications:

1. Create a `.argocd-envsubst` file in your application directory
2. Use `${VAR_NAME}` syntax in your YAML files
3. Configure the ArgoCD Application to use the plugin:

```yaml
spec:
  source:
    plugin:
      name: envsubst
```

## Available Variables

Check the ConfigMap for available variables:

```bash
kubectl get configmap argocd-env-vars -n argocd -o yaml
```

You can also use variables from:
- `argocd-env-secrets` secret (if created)
- Any environment variables set in the plugin container