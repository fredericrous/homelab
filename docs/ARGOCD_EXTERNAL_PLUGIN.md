# Using the External ArgoCD Envsubst Plugin

This guide explains how to use the externalized ArgoCD environment substitution plugin.

## Installation Methods

### Method 1: As a Sidecar (Recommended for v2)

```yaml
# argocd-repo-server-patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: argocd-repo-server
  namespace: argocd
spec:
  template:
    spec:
      containers:
      - name: envsubst-plugin
        image: ghcr.io/fredericrous/argocd-envsubst-plugin:v1.0.0
        command: ["/var/run/argocd/argocd-cmp-server"]
        envFrom:
        - secretRef:
            name: argocd-env
        volumeMounts:
        - name: var-files
          mountPath: /var/run/argocd
        - name: plugins
          mountPath: /home/argocd/cmp-server/plugins
      volumes:
      - name: var-files
        emptyDir: {}
      - name: plugins
        emptyDir: {}
```

Apply:
```bash
kubectl patch deployment argocd-repo-server -n argocd --patch "$(cat argocd-repo-server-patch.yaml)"
```

### Method 2: Using Helm

```bash
# Add the plugin repository
helm repo add fredericrous https://fredericrous.github.io/charts
helm repo update

# Install the plugin
helm install argocd-envsubst fredericrous/argocd-envsubst-plugin \
  --namespace argocd \
  --values - <<EOF
envFrom:
- secretRef:
    name: argocd-env
EOF
```

### Method 3: Using Kustomize

```yaml
# kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- https://github.com/fredericrous/argocd-envsubst-plugin/deploy?ref=v1.0.0

patchesStrategicMerge:
- |-
  apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: argocd-repo-server
    namespace: argocd
  spec:
    template:
      spec:
        containers:
        - name: envsubst-plugin
          envFrom:
          - secretRef:
              name: argocd-env
```

## Using the Plugin in Applications

### ApplicationSet Configuration

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: core-apps
  namespace: argocd
spec:
  template:
    spec:
      source:
        plugin:
          name: kustomize-envsubst  # Plugin auto-discovered
```

### Individual Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vault
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/fredericrous/homelab
    targetRevision: main
    path: manifests/core/vault
    plugin:
      name: kustomize-envsubst
```

## Plugin Discovery

The plugin automatically activates when it finds:
- `kustomization.yaml` in the directory
- `${VARIABLE}` patterns in the manifests

You can also force it with:
```yaml
source:
  plugin:
    name: kustomize-envsubst
```

## Benefits of External Plugin

1. **Version Control**: Plugin updates independent of homelab
2. **Reusability**: Use in multiple clusters/projects
3. **Testing**: Easier to test and validate
4. **Community**: Others can contribute improvements
5. **CI/CD**: Automated builds and releases

## Migration from Inline Plugin

1. Remove the old ConfigMap:
```bash
kubectl delete configmap argocd-cm -n argocd
```

2. Install the external plugin (see above)

3. Update applications to use the plugin name

4. No changes needed to manifests - same `${VARIABLE}` syntax

## Troubleshooting

Check plugin is registered:
```bash
kubectl logs -n argocd deployment/argocd-repo-server | grep envsubst
```

Check sidecar is running:
```bash
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].spec.containers[*].name}'
```

Test plugin locally:
```bash
docker run --rm -v $(pwd):/workdir -w /workdir \
  ghcr.io/fredericrous/argocd-envsubst-plugin:latest \
  /usr/local/bin/argocd-envsubst-plugin generate
```