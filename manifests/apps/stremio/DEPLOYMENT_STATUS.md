# Stremio Web Deployment Status

## ✅ Completed Tasks
1. Successfully built Stremio Web Docker image
2. Successfully pushed to Harbor registry at `harbor-registry.harbor.svc.cluster.local:5000/library/stremio-web:latest`
3. Updated Harbor configuration with proper htpasswd through GitOps
4. Applied Talos machine configuration patch for insecure registry

## Current Status
The image is successfully stored in Harbor but Kubernetes nodes cannot pull it because:
- Talos containerd is still trying to use HTTPS despite the configuration patch
- The registry configuration changes may require a node reboot to take full effect

## Verification
```bash
# Image exists in Harbor registry
curl -u harbor_registry_user:33V4wUaUxgEC2cFEqENfkv \
  http://harbor-registry.harbor.svc.cluster.local:5000/v2/library/stremio-web/tags/list
# Returns: {"name":"library/stremio-web","tags":["latest"]}

# Talos configuration has been updated
talosctl get mc -o yaml | grep -A20 registries
# Shows the correct registry mirrors and auth configuration
```

## Next Steps
To complete the deployment:

1. **Option 1: Reboot nodes** (Recommended)
   ```bash
   talosctl reboot -n 192.168.1.67,192.168.1.68,192.168.1.69
   ```
   This will ensure containerd picks up the new registry configuration.

2. **Option 2: Wait for automatic refresh**
   Talos may eventually pick up the configuration changes without a reboot.

3. **Option 3: Use external Harbor URL**
   Configure nodes with mTLS client certificates to use `harbor.daddyshome.fr`

## Configuration Applied
The following Talos patch was successfully applied to all nodes:
- Registry mirrors configured for HTTP endpoints
- Authentication configured for harbor_registry_user
- TLS verification disabled for Harbor registries