#!/bin/bash
# Validate NAS Integration Monitoring Setup
set -euo pipefail

echo "🔍 NAS Integration Monitoring Validation"
echo "========================================"

# Configuration
MONITORING_NS="monitoring"
NAS_INTEGRATION_NS="nas-integration"

# Check if monitoring namespace exists
if ! kubectl get namespace "$MONITORING_NS" >/dev/null 2>&1; then
    echo "❌ Monitoring namespace '$MONITORING_NS' not found"
    exit 1
fi

echo "✅ Monitoring namespace exists"

# Check Prometheus Rules
echo ""
echo "📋 Checking Prometheus Rules..."
if kubectl get prometheusrule nas-integration-alerts -n "$MONITORING_NS" >/dev/null 2>&1; then
    echo "✅ NAS Integration alerts configured"
    
    # Count alert rules
    ALERT_COUNT=$(kubectl get prometheusrule nas-integration-alerts -n "$MONITORING_NS" -o json | jq '.spec.groups[].rules | length' | awk '{sum+=$1} END {print sum}')
    echo "   📊 Total alert rules: $ALERT_COUNT"
else
    echo "❌ NAS Integration alerts not found"
fi

# Check ServiceMonitor
echo ""
echo "📈 Checking ServiceMonitor..."
if kubectl get servicemonitor nas-integration-metrics -n "$MONITORING_NS" >/dev/null 2>&1; then
    echo "✅ ServiceMonitor configured for NAS integration"
else
    echo "❌ ServiceMonitor for NAS integration not found"
fi

# Check Grafana Dashboard
echo ""
echo "📊 Checking Grafana Dashboard..."
if kubectl get configmap nas-integration-dashboard -n "$MONITORING_NS" >/dev/null 2>&1; then
    echo "✅ NAS Integration Grafana dashboard configured"
else
    echo "❌ NAS Integration dashboard not found"
fi

# Check External Secrets metrics availability
echo ""
echo "🔍 Validating External Secrets Metrics..."
if kubectl get pods -n external-secrets-system -l app.kubernetes.io/name=external-secrets >/dev/null 2>&1; then
    echo "✅ External Secrets Operator is running"
    
    # Check if metrics endpoint is accessible
    ESO_POD=$(kubectl get pods -n external-secrets-system -l app.kubernetes.io/name=external-secrets -o name | head -1)
    if [[ -n "$ESO_POD" ]]; then
        echo "   🔍 Checking metrics endpoint..."
        if kubectl exec -n external-secrets-system "$ESO_POD" -- wget -qO- http://localhost:8080/metrics | grep -q "externalsecret_sync_calls_total"; then
            echo "   ✅ External Secrets metrics available"
        else
            echo "   ⚠️  External Secrets metrics endpoint might not be ready"
        fi
    fi
else
    echo "❌ External Secrets Operator not found"
fi

# Check Istio metrics availability
echo ""
echo "🌐 Validating Istio/Envoy Metrics..."
if kubectl get pods -n istio-system -l app=istiod >/dev/null 2>&1; then
    echo "✅ Istio is running"
    
    # Check if we have any Envoy sidecars in nas-integration namespace
    if kubectl get pods -n "$NAS_INTEGRATION_NS" 2>/dev/null | grep -q "2/2\|3/3"; then
        echo "   ✅ Istio sidecars detected in NAS integration"
    else
        echo "   ⚠️  No Istio sidecars found - Envoy metrics may not be available"
    fi
else
    echo "❌ Istio not found"
fi

# Check if NAS integration namespace exists
echo ""
echo "🏠 Validating NAS Integration Components..."
if kubectl get namespace "$NAS_INTEGRATION_NS" >/dev/null 2>&1; then
    echo "✅ NAS integration namespace exists"
    
    # Check External Secret
    if kubectl get externalsecret nas-vault-token -n "$NAS_INTEGRATION_NS" >/dev/null 2>&1; then
        echo "   ✅ External Secret configured"
        
        # Check sync status
        SYNC_STATUS=$(kubectl get externalsecret nas-vault-token -n "$NAS_INTEGRATION_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        echo "   📋 Sync status: $SYNC_STATUS"
    else
        echo "   ❌ External Secret not found"
    fi
    
    # Check CronJob
    if kubectl get cronjob nas-token-broker -n "$NAS_INTEGRATION_NS" >/dev/null 2>&1; then
        echo "   ✅ Token broker CronJob configured"
        
        # Check recent job status
        RECENT_JOB=$(kubectl get jobs -n "$NAS_INTEGRATION_NS" -l job-name --sort-by=.metadata.creationTimestamp -o name | tail -1)
        if [[ -n "$RECENT_JOB" ]]; then
            JOB_STATUS=$(kubectl get "$RECENT_JOB" -n "$NAS_INTEGRATION_NS" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "Unknown")
            echo "   📋 Recent job status: $JOB_STATUS"
        fi
    else
        echo "   ❌ Token broker CronJob not found"  
    fi
    
    # Check Secret
    if kubectl get secret nas-vault-token -n "$NAS_INTEGRATION_NS" >/dev/null 2>&1; then
        echo "   ✅ NAS token secret exists"
        
        # Check token age
        LAST_REFRESH=$(kubectl get secret nas-vault-token -n "$NAS_INTEGRATION_NS" -o jsonpath='{.metadata.annotations.homelab\.io/last-refresh}' 2>/dev/null || echo "")
        if [[ -n "$LAST_REFRESH" ]]; then
            echo "   📅 Last refresh: $LAST_REFRESH"
        fi
    else
        echo "   ❌ NAS token secret not found"
    fi
else
    echo "❌ NAS integration namespace not found"
fi

# Monitoring endpoints summary
echo ""
echo "📊 Monitoring Endpoints Summary:"
echo "================================"
echo "Prometheus Alerts: kubectl get prometheusrule nas-integration-alerts -n $MONITORING_NS"
echo "Grafana Dashboard: Access via Grafana UI -> 'NAS Integration Monitoring'"
echo "External Secrets Metrics: kubectl port-forward -n external-secrets-system svc/external-secrets-webhook 8080:8080"
echo "Istio Metrics: kubectl exec -n nas-integration <pod> -- curl localhost:15000/stats | grep nas"
echo ""
echo "Key Metrics to Monitor:"
echo "- externalsecret_sync_calls_total"
echo "- externalsecret_sync_calls_error"  
echo "- kube_job_status_succeeded{job_name=~\"nas-token-broker-.*\"}"
echo "- kube_job_status_failed{job_name=~\"nas-token-broker-.*\"}"
echo "- envoy_cluster_outlier_detection_ejections_active"
echo "- envoy_cluster_upstream_rq_xx{envoy_response_code_class=\"5\"}"
echo ""
echo "✅ Monitoring validation complete!"