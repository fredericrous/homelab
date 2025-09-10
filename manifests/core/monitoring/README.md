# Monitoring Stack

This directory contains the complete monitoring infrastructure for the homelab cluster.

## Components

### 1. **kube-prometheus-stack**
- **Prometheus**: Metrics collection and storage
- **Grafana**: Visualization and dashboards
- **AlertManager**: Alert routing and notification
- **Prometheus Operator**: CRD-based configuration

### 2. **Loki**
- Log aggregation and storage
- Integrated with Grafana for log viewing
- Receives logs from Tetragon and Promtail

### 3. **Promtail**
- Log collector running on every node
- Ships logs to Loki
- Collects system logs, container logs, and audit logs

## Architecture

```
┌─────────────┐     ┌─────────────┐     ┌──────────────┐
│  Metrics    │────▶│ Prometheus  │────▶│   Grafana    │
│  Endpoints  │     │             │     │              │
└─────────────┘     └─────────────┘     │              │
                            │            │              │
┌─────────────┐     ┌─────────────┐     │              │
│    Logs     │────▶│    Loki     │────▶│              │
│  (Tetragon) │     │             │     └──────────────┘
└─────────────┘     └─────────────┘             │
                                                ▼
┌─────────────┐                        ┌──────────────┐
│  Promtail   │────────────────────────▶ AlertManager │
│  (DaemonSet)│                        └──────────────┘
└─────────────┘
```

## Access

### Grafana
- **URL**: https://grafana.daddyshome.fr
- **Username**: admin
- **Password**: Retrieved from Vault at `secret/monitoring/grafana`

### Prometheus
- **Internal**: http://kube-prometheus-stack-prometheus.monitoring:9090
- **Metrics**: http://kube-prometheus-stack-prometheus.monitoring:9090/metrics

### Loki
- **Internal**: http://loki.monitoring:3100
- **Push API**: http://loki-gateway.monitoring:3100/loki/api/v1/push

### AlertManager
- **URL**: https://alertmanager.daddyshome.fr
- **Internal**: http://kube-prometheus-stack-alertmanager.monitoring:9093

## Configuration

### Adding Prometheus Scrape Targets
Edit `prometheus-values.yaml` and add to `additionalScrapeConfigs`:

```yaml
additionalScrapeConfigs:
  - job_name: 'my-service'
    static_configs:
      - targets: ['my-service.namespace:8080']
```

### Adding Grafana Dashboards
Create a ConfigMap with the dashboard JSON:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
    grafana_folder: "My Folder"
data:
  my-dashboard.json: |
    {
      "dashboard": { ... }
    }
```

### Configuring Alerts
Add PrometheusRule resources:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: my-alerts
  namespace: monitoring
  labels:
    prometheus: kube-prometheus
spec:
  groups:
    - name: my-alerts
      rules:
        - alert: MyAlert
          expr: up == 0
          for: 5m
```

## Storage

All components use persistent storage backed by Rook-Ceph:
- **Prometheus**: 50GB on ceph-block (15 days retention)
- **Grafana**: 10GB on ceph-block (dashboards & config)
- **AlertManager**: 5GB on ceph-block (alert history)
- **Loki**: 30GB + 50GB backend on ceph-filesystem (30 days retention)
- **Total**: ~145GB across Ceph cluster (replicated)

With Rook-Ceph pooling ~1.96TB across nodes, this represents <10% utilization.

## Security

- All credentials stored in Vault
- Network policies restrict access
- TLS enabled for all ingresses
- Basic auth for AlertManager

## Troubleshooting

### Prometheus Not Scraping
```bash
# Check ServiceMonitor
kubectl get servicemonitor -A

# Check Prometheus config
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- promtool check config /etc/prometheus/prometheus.yml
```

### Loki Not Receiving Logs
```bash
# Check Promtail
kubectl logs -n monitoring -l app.kubernetes.io/name=promtail

# Test Loki API
curl -X POST http://loki.monitoring:3100/loki/api/v1/push \
  -H "Content-Type: application/json" \
  -d '{"streams": [{"stream": {"test": "test"}, "values": [["'$(date +%s%N)'", "test log"]]}]}'
```

### Grafana Login Issues
```bash
# Check secret from Vault
kubectl get secret grafana-admin-credentials -n monitoring -o yaml

# Reset admin password
kubectl exec -n monitoring deployment/kube-prometheus-stack-grafana -- grafana-cli admin reset-admin-password newpassword
```

## Dashboards

Pre-configured dashboards include:
- **Kubernetes Cluster**: Node and pod metrics
- **Security Audit**: Tetragon events
- **Vault Metrics**: Operations and performance
- **Ingress**: HAProxy metrics
- **Storage**: Rook-Ceph dashboard

## Alerts

Default alerts include:
- Node down/pressure
- Pod crashes and restarts  
- High CPU/memory usage
- Disk space warnings
- Certificate expiration
- Security violations (via Tetragon)

## Integration with Tetragon

Tetragon ships security events to:
1. **Loki**: For log storage and search
2. **Prometheus**: For metrics and alerting

Example queries:
```logql
# Security events in Loki
{component="tetragon"} |= "privilege_escalation"

# Metrics in Prometheus
sum(rate(tetragon_events_total[5m])) by (event_type)
```