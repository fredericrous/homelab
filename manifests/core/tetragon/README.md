# Tetragon Security Audit Logging

This directory contains the Tetragon-based security audit logging infrastructure for the homelab cluster.

## Overview

Tetragon provides eBPF-based runtime security observability and enforcement. It tracks:
- Process execution and system calls
- Network connections
- File access patterns
- Privilege escalation attempts
- Vault access and operations
- Container escape attempts

## Architecture

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│   Kernel    │────▶│   Tetragon   │────▶│    Loki     │
│   Events    │     │   (eBPF)     │     │  (Storage)  │
└─────────────┘     └──────────────┘     └─────────────┘
                            │                     │
                            ▼                     ▼
                    ┌──────────────┐     ┌─────────────┐
                    │ Prometheus   │     │   Grafana   │
                    │  (Metrics)    │     │(Dashboards) │
                    └──────────────┘     └─────────────┘
                            │
                            ▼
                    ┌──────────────┐
                    │ AlertManager │
                    │   (Alerts)    │
                    └──────────────┘
```

## Components

### 1. Tetragon Core
- Deploys Tetragon DaemonSet on all nodes
- Collects kernel-level security events via eBPF
- Exports events to Loki for storage
- Exposes Prometheus metrics

### 2. Security Policies
- **base-audit.yaml**: Core audit logging (process exec, file access, network)
- **sensitive-operations.yaml**: Tracks privilege escalation and capability usage
- **vault-access.yaml**: Monitors Vault operations and API access
- **privilege-escalation.yaml**: Detects sudo, kernel modules, container escapes

### 3. Integration Points
- **Loki**: Centralized log storage and querying
- **Prometheus**: Metrics and alerting
- **Grafana**: Security dashboards
- **AlertManager**: Real-time security alerts

## Deployment

```bash
# Deploy via ArgoCD
kubectl apply -f app.yaml

# Or manually
kubectl apply -k .
```

## Configuration

### Enable/Disable Policies
Edit `kustomization.yaml` to include/exclude specific policies:

```yaml
configMapGenerator:
  - name: tetragon-policies
    files:
      # Comment out policies to disable
      - policies/base-audit.yaml
      # - policies/sensitive-operations.yaml
```

### Adjust Resource Limits
Edit `values.yaml`:

```yaml
tetragon:
  resources:
    limits:
      memory: 2Gi  # Adjust based on cluster size
      cpu: 2000m
```

### Change Enforcement Mode
Switch from audit to enforcement in `values.yaml`:

```yaml
tetragon:
  enforcementMode: "enforce"  # or "audit"
```

## Viewing Audit Logs

### Via Grafana
1. Access Grafana: `https://grafana.daddyshome.fr`
2. Navigate to "Security Audit Dashboard"
3. View real-time security events

### Via Loki (LogQL)
```bash
# All security events
{component="tetragon"} |= "event_type"

# Privilege escalation attempts
{component="tetragon"} |= "privilege_escalation"

# Vault access logs
{component="tetragon"} |= "vault" |= "tcp_connect"

# File access to sensitive paths
{component="tetragon"} |= "file_open" |~ "/etc/kubernetes/pki"
```

### Via kubectl
```bash
# View Tetragon logs
kubectl logs -n tetragon -l app.kubernetes.io/name=tetragon -f

# View specific policy violations
kubectl logs -n tetragon -l app.kubernetes.io/name=tetragon | grep -i privilege
```

## Alerts

Security alerts are sent via AlertManager:

| Alert | Severity | Description |
|-------|----------|-------------|
| PrivilegeEscalationAttempt | Critical | Detected sudo/su usage or capability escalation |
| UnauthorizedVaultAccess | High | Failed Vault authentication attempts |
| SuspiciousFileAccess | Warning | Access to sensitive Kubernetes files |
| ContainerEscapeAttempt | Critical | Namespace breakout attempts |
| UnauthorizedKernelModule | High | Kernel module loading detected |

## Troubleshooting

### High Memory Usage
Tetragon can consume significant memory with many policies:
```bash
# Check memory usage
kubectl top pods -n tetragon

# Reduce cache size in values.yaml
processCacheSize: 32768  # Default: 65536
```

### Missing Events
Check if BPF programs are loaded:
```bash
kubectl exec -n tetragon -it $(kubectl get pods -n tetragon -l app.kubernetes.io/name=tetragon -o name | head -1) -- tetra status
```

### Policy Not Working
Validate policy syntax:
```bash
kubectl apply -f policies/your-policy.yaml --dry-run=server
```

## Security Considerations

1. **Privileged Access**: Tetragon runs with privileged access to monitor the kernel
2. **Log Retention**: Audit logs may contain sensitive information - ensure proper retention policies
3. **Performance Impact**: eBPF is efficient but monitoring everything can impact performance
4. **False Positives**: Tune policies to reduce noise from legitimate operations

## Best Practices

1. Start in audit mode before enabling enforcement
2. Test policies in development before production
3. Regularly review audit logs for anomalies
4. Keep Tetragon updated for latest security features
5. Monitor resource usage and adjust limits accordingly

## References

- [Tetragon Documentation](https://tetragon.io/docs/)
- [eBPF Security Observability](https://ebpf.io/what-is-ebpf/#security)
- [Kubernetes Audit Logging](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)