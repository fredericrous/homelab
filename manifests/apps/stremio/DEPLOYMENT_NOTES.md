# Stremio Web Deployment Notes

## Current Status
- ✅ Successfully built Stremio Web Docker image
- ✅ Successfully pushed to Harbor private registry at `harbor-registry.harbor.svc.cluster.local:5000/library/stremio-web:latest`
- ⚠️  Cannot pull from Harbor due to Talos containerd configuration requiring HTTPS

## Issue
Talos nodes' containerd is configured to use HTTPS by default and requires TLS certificates. The Harbor registry is running with HTTP internally. Configuring Talos nodes for insecure registries requires:
1. Creating machine config patches
2. Applying them to all nodes
3. Rebooting nodes

## Solutions

### Option 1: Configure Talos for Insecure Registry (Recommended for production)
Add this patch to your Talos machine config:
```yaml
machine:
  files:
    - content: |
        [plugins."io.containerd.grpc.v1.cri".registry]
          [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
            [plugins."io.containerd.grpc.v1.cri".registry.mirrors."harbor-registry.harbor.svc.cluster.local:5000"]
              endpoint = ["http://harbor-registry.harbor.svc.cluster.local:5000"]
          [plugins."io.containerd.grpc.v1.cri".registry.configs]
            [plugins."io.containerd.grpc.v1.cri".registry.configs."harbor-registry.harbor.svc.cluster.local:5000".tls]
              insecure_skip_verify = true
      path: /etc/cri/conf.d/harbor.toml
      op: create
```

### Option 2: Manual Image Import (Quick workaround)
Use the export-import script to manually load the image on nodes where Stremio will run.

### Option 3: Use External Harbor URL with mTLS
Configure nodes with client certificates for mTLS authentication to Harbor's external URL.

## Verification
The image is successfully stored in Harbor and can be accessed:
```bash
curl -u harbor_registry_user:33V4wUaUxgEC2cFEqENfkv \
  http://harbor-registry.harbor.svc.cluster.local:5000/v2/library/stremio-web/tags/list
# Returns: {"name":"library/stremio-web","tags":["latest"]}
```