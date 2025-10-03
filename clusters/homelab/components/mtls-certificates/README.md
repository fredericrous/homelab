# mtls-certificates Component

This is a Kustomize component that provides mTLS client certificate support for applications using Istio.

## What it does

1. Creates an ExternalSecret to sync the client CA certificate from Vault
2. Creates an ExternalSecret for Istio-specific CA configuration  
3. Runs a job to patch TLS certificates with the `cacert` key required by Istio MUTUAL mode
4. Works with Reflector to automatically propagate the patched certificate to istio-ingress

## Usage

1. Add the component to your application's kustomization.yaml:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

components:
  - ../../components/mtls-certificates

resources:
  - namespace.yaml
  - deployment.yaml
  # ... other resources

# Configuration for mTLS component
configMapGenerator:
- name: mtls-config
  literals:
  - serviceAccount=your-service-account
```

2. Add annotation to your namespace:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: your-app
  annotations:
    # mTLS component configuration
    mtls/tls-secret-name: "your-tls-secret"
```

3. Ensure your Certificate has reflector annotations:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: your-tls
spec:
  secretTemplate:
    annotations:
      reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
      reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "istio-ingress"
      reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
```

## How it works

1. The component syncs the client CA certificate from Vault
2. When cert-manager creates the TLS certificate, the patch job adds the `cacert` key
3. Reflector automatically propagates the complete certificate (including cacert) to istio-ingress
4. Istio Gateway can now use MUTUAL TLS mode with the certificate