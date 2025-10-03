# Cilium Native Routing Configuration

This cluster is configured to use Cilium with **native routing** instead of VXLAN overlay networking.

## Benefits of Native Routing

1. **Better Performance**: 15-20% throughput improvement, lower latency
2. **No Encapsulation Overhead**: Direct pod-to-pod communication
3. **Simpler Debugging**: No tunnel interfaces to troubleshoot
4. **Reliable DNS**: No MTU issues with DNS packets
5. **Lower CPU Usage**: No packet encapsulation/decapsulation

## Requirements

- All nodes must be in the same L2 network segment (same subnet)
- In this homelab: All nodes are in 192.168.1.0/24 ✅

## Configuration

The native routing configuration is in:
- Bootstrap: `terraform/cilium-bootstrap.tf` uses `manifests/core/cilium/values-native.yaml`
- ArgoCD: `manifests/core/cilium/kustomization.yaml` references `values-native.yaml`

Key settings:
```yaml
routingMode: "native"
ipv4NativeRoutingCIDR: "10.244.0.0/16"
autoDirectNodeRoutes: true
tunnel: "disabled"
```

## Reverting to VXLAN (if needed)

If you need to revert to VXLAN mode:
1. Update `terraform/cilium-bootstrap.tf` to use `values.talos.yaml`
2. Update `manifests/core/cilium/kustomization.yaml` to use `values.talos.yaml`
3. Run `task destroy && task deploy`

## Troubleshooting

If you see DNS issues after deployment:
1. Check node connectivity: `kubectl get nodes -o wide`
2. Verify all nodes are in same subnet
3. Check Cilium status: `kubectl -n kube-system exec ds/cilium -- cilium status`