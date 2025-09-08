# NVIDIA Version Management

## Overview

The NVIDIA device plugin requires the node selector version to match the installed NVIDIA driver version on the GPU nodes. This ensures proper GPU detection and allocation.

## Current Configuration

- **Driver Version**: 570.148.08
- **Container Toolkit Version**: v1.17.8
- **Node Selector**: `extensions.talos.dev/nvidia-container-toolkit-production: "570.148.08-v1.17.8"`

## Checking Node Driver Version

To check the NVIDIA driver version on a node:

```bash
# Option 1: Check Talos extension
kubectl get nodes -o yaml | grep nvidia-container-toolkit

# Option 2: If NVIDIA pods are running
kubectl exec -n kube-system nvidia-device-plugin-daemonset-<pod> -- nvidia-smi | grep "Driver Version"
```

## Updating Version

When the NVIDIA driver is updated on the nodes, update all manifests:

1. Find all files with the node selector:
```bash
grep -r "nvidia-container-toolkit-production" manifests/core/nvidia-device-plugin/
```

2. Update all occurrences to the new version:
```bash
# Example: Update from 570.148.08-v1.17.8 to 580.x.x-v1.y.z
sed -i 's/570.148.08-v1.17.8/580.x.x-v1.y.z/g' manifests/core/nvidia-device-plugin/*.yaml
```

3. Apply the changes:
```bash
kubectl apply -k manifests/core/nvidia-device-plugin/
```

4. Verify pods are running:
```bash
kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds
```

5. Check GPU detection:
```bash
kubectl describe node <gpu-node-name> | grep nvidia.com/gpu
```

## Troubleshooting

### Pods not scheduling

If NVIDIA pods show 0/0 desired:
```bash
kubectl get daemonsets -n kube-system | grep nvidia
```

This usually means the node selector doesn't match any nodes. Check the installed version on nodes.

### GPU not detected

After pods are running, if GPUs show as 0:
```bash
# Check device plugin logs
kubectl logs -n kube-system -l name=nvidia-device-plugin-ds

# Check node labels
kubectl get nodes --show-labels | grep nvidia
```

## GitOps Automation

When updating versions:
1. Make changes to all YAML files
2. Commit and push to git
3. ArgoCD will automatically sync the changes

This ensures the version update is tracked and reproducible across environments.