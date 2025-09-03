# DNS Workaround for Talos + Cilium

## Issue
Pods cannot connect to DNS service IP (10.96.0.10:53) with error "operation not permitted".
This appears to be a kernel/eBPF restriction specific to UDP port 53 on service IPs.

## Root Cause
- DNS works when accessing CoreDNS pods directly (e.g., 10.244.0.111:53)
- DNS fails only when using the service IP (10.96.0.10:53)
- Issue persists even with:
  - Cilium 1.18.1 (latest)
  - forwardKubeDNSToHost disabled
  - DNS proxy disabled
  - rp_filter=0 sysctls applied

## Workaround
Configure pods to use CoreDNS pod IPs directly instead of service IP:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: example
spec:
  dnsPolicy: None
  dnsConfig:
    nameservers:
    - 10.244.0.111  # CoreDNS pod on control plane
    - 10.244.2.241  # CoreDNS pod on worker
    searches:
    - default.svc.cluster.local
    - svc.cluster.local
    - cluster.local
    options:
    - name: ndots
      value: "5"
```

## Impact
- ArgoCD and other services will work once they use this DNS configuration
- This is a temporary workaround until the root cause is identified
- CoreDNS pod IPs may change after restarts - monitor and update as needed

## Next Steps
1. Configure critical services (ArgoCD, cert-manager) with this DNS workaround
2. Continue investigating the kernel-level restriction
3. Report issue to Talos/Cilium maintainers