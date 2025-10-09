#!/bin/bash
# Don't use set -e because we want to continue even if some components aren't ready yet

# Handle interruption signals to exit cleanly
trap 'echo ""; echo "❌ Infrastructure verification interrupted by user"; exit 130' INT TERM
trap 'echo "DEBUG: Script failed at line $LINENO"' ERR

echo "⏳ Waiting for infrastructure components to be ready..."

# Wait for Flux to create the kustomizations first
echo "Waiting for kustomizations to be created..."
for i in {1..30}; do
  if kubectl get kustomization platform-foundation -n flux-system >/dev/null 2>&1; then
    echo "✓ platform-foundation kustomization found"
    break
  fi
  echo "Waiting for platform-foundation kustomization... ($i/30)"
  sleep 2
done

# Wait for platform foundation first (includes Rook-Ceph, Vault, ESO, Istio)
echo "Waiting for platform foundation components..."
kubectl wait --for=condition=ready --timeout=600s -n flux-system kustomization/platform-foundation 2>/dev/null || {
  echo "⚠️  Platform foundation not ready yet, checking status..."
  kubectl get kustomization platform-foundation -n flux-system 2>/dev/null || echo "Platform-foundation kustomization not found"
}

# Wait for Rook-Ceph to be fully healthy before proceeding
echo "🗄️  Verifying Rook-Ceph cluster health..."
echo "Waiting for Rook operator to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/rook-ceph-operator -n rook-ceph 2>/dev/null || {
  echo "⚠️  Rook operator not ready yet"
  kubectl get pods -n rook-ceph -l app=rook-ceph-operator 2>/dev/null || echo "Rook operator not found"
}

echo "Waiting for CephCluster resource to be created..."
for i in {1..60}; do
  if kubectl get cephcluster rook-ceph -n rook-ceph >/dev/null 2>&1; then
    echo "✓ CephCluster resource found"
    break
  fi
  echo "Waiting for CephCluster... ($i/60)"
  sleep 5
done

echo "Waiting for all 3 Ceph monitors to be running..."
for i in {1..120}; do
  # Count running monitors
  running_mons=$(kubectl get pods -n rook-ceph -l app=rook-ceph-mon --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  running_mons=$(echo "$running_mons" | head -n1 | tr -d '\n\r ')
  total_mons=$(kubectl get pods -n rook-ceph -l app=rook-ceph-mon --no-headers 2>/dev/null | wc -l | tr -d '\n\r ' || echo "0")

  if [ "$running_mons" -eq 3 ]; then
    echo "✅ All 3 Ceph monitors are running"
    break
  elif [ "$total_mons" -gt 0 ]; then
    echo "Waiting for monitors: $running_mons/3 running ($i/120)"

    # Show monitor status every 30 iterations (2.5 minutes)
    if [ $((i % 30)) -eq 0 ]; then
      echo "Monitor status:"
      kubectl get pods -n rook-ceph -l app=rook-ceph-mon -o wide 2>/dev/null || echo "  No monitors found"
      echo "Node resource usage:"
      kubectl top nodes 2>/dev/null || echo "  Metrics not available"
    fi
  else
    echo "Waiting for monitor pods to be created... ($i/120)"
  fi

  sleep 5
done

echo "Waiting for Ceph OSDs to be ready..."
for i in {1..120}; do
  running_osds=$(kubectl get pods -n rook-ceph -l app=rook-ceph-osd --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  running_osds=$(echo "$running_osds" | head -n1 | tr -d '\n\r ')
  total_osds=$(kubectl get pods -n rook-ceph -l app=rook-ceph-osd --no-headers 2>/dev/null | wc -l | tr -d '\n\r ' || echo "0")

  if [ "$running_osds" -gt 0 ]; then
    echo "✅ Found $running_osds running OSD(s)"
    break
  fi

  echo "Waiting for OSDs: $running_osds/$total_osds running ($i/120)"

  # Show OSD status every 30 iterations (2.5 minutes)
  if [ $((i % 30)) -eq 0 ] && [ "$total_osds" -gt 0 ]; then
    echo "OSD pod status:"
    kubectl get pods -n rook-ceph -l app=rook-ceph-osd -o wide 2>/dev/null || echo "  No OSD pods found"

    # Check if OSD prepare jobs are still running
    prepare_jobs=$(kubectl get pods -n rook-ceph -l app=rook-ceph-osd-prepare --no-headers 2>/dev/null | grep -v "Completed" | wc -l | tr -d '\n\r ' || echo "0")
    if [ "$prepare_jobs" -gt 0 ]; then
      echo "  ⏳ $prepare_jobs OSD prepare job(s) still running"
    fi
  fi

  sleep 5
done

# Check Ceph health before testing storage
echo "Checking Ceph cluster health..."
mgr_pod=$(kubectl get pods -n rook-ceph -l app=rook-ceph-mgr --no-headers 2>/dev/null | grep Running | head -1 | awk '{print $1}')
if [ -n "$mgr_pod" ]; then
  health_status=$(kubectl exec -n rook-ceph "$mgr_pod" -- ceph health 2>/dev/null || echo "UNKNOWN")
  echo "Ceph health: $health_status"

  # Show more details if health is not OK
  if [[ ! "$health_status" =~ ^HEALTH_OK ]]; then
    echo "Ceph status details:"
    kubectl exec -n rook-ceph "$mgr_pod" -- ceph status 2>/dev/null || echo "  Could not get Ceph status"
  fi
else
  echo "⚠️  No running Ceph manager pod found, skipping health check"
fi

# Check CSI driver pods are ready
echo "Checking Ceph CSI driver readiness..."
csi_ready=$(kubectl get pods -n rook-ceph -l app=csi-rbdplugin --no-headers 2>/dev/null | grep -c "Running" 2>/dev/null || echo "0")
csi_total=$(kubectl get pods -n rook-ceph -l app=csi-rbdplugin --no-headers 2>/dev/null | wc -l 2>/dev/null || echo "0")
csi_ready=$(echo "$csi_ready" | tr -d '\n\r ')
csi_total=$(echo "$csi_total" | tr -d '\n\r ')
if [ "$csi_ready" -eq "$csi_total" ] && [ "$csi_total" -gt 0 ]; then
  echo "✅ Ceph CSI driver ready ($csi_ready/$csi_total pods running)"
else
  echo "⚠️  Ceph CSI driver not fully ready ($csi_ready/$csi_total pods running)"
fi

echo "Testing Ceph storage provisioning..."
# Create a test PVC to ensure storage is working
kubectl apply -f - <<EOF >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-rook-health
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: rook-ceph-block
  resources:
    requests:
      storage: 1Gi
EOF

# Wait for test PVC to be bound
for i in {1..60}; do  # 5 minutes total
  pvc_status=$(kubectl get pvc test-rook-health -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  if [ "$pvc_status" = "Bound" ]; then
    echo "✅ Ceph storage provisioning is working"
    kubectl delete pvc test-rook-health -n default --wait=false >/dev/null 2>&1
    break
  fi
  echo "Testing storage provisioning: $pvc_status ($i/60)"

  # Show more details every 20 iterations (100 seconds)
  if [ $((i % 20)) -eq 0 ] && [ "$i" -gt 1 ]; then
    echo "PVC events:"
    kubectl describe pvc test-rook-health -n default 2>/dev/null | tail -10 | grep -E "Events:|Normal|Warning" || echo "  No events found"
  fi

  sleep 5
done

# Check if storage provisioning succeeded
if [ "$pvc_status" = "Bound" ]; then
  echo "✅ Rook-Ceph cluster is healthy and ready"
else
  echo "⚠️  Storage provisioning test failed after timeout"
  echo "PVC status: $pvc_status"
  echo "Ceph cluster may need more time to initialize or there may be configuration issues"
  # Clean up test PVC if it exists
  kubectl delete pvc test-rook-health -n default --wait=false >/dev/null 2>&1
fi

# Wait for security layer (includes cert-manager)
echo "Waiting for security layer..."
kubectl wait --for=condition=ready --timeout=600s -n flux-system kustomization/security 2>/dev/null || {
  echo "⚠️  Security layer not ready yet, checking status..."
  kubectl get kustomization security -n flux-system 2>/dev/null || echo "Security kustomization not found"
}

# Wait for data-storage layer (includes CloudNativePG)
echo "Waiting for data-storage layer..."
kubectl wait --for=condition=ready --timeout=600s -n flux-system kustomization/data-storage 2>/dev/null || {
  echo "⚠️  Data-storage layer not ready yet, checking status..."
  kubectl get kustomization data-storage -n flux-system 2>/dev/null || echo "Data-storage kustomization not found"
}

# Wait for Vault HelmRelease
echo "Waiting for Vault..."
kubectl wait --for=condition=ready --timeout=600s -n flux-system helmrelease/vault 2>/dev/null || {
  echo "⚠️  Vault not ready yet"
  kubectl get helmrelease vault -n flux-system 2>/dev/null || echo "Vault HelmRelease not found"
}

# Wait for Vault to be initialized
echo "Waiting for Vault initialization..."
for i in {1..60}; do
  if kubectl get secret vault-admin-token -n vault >/dev/null 2>&1; then
    echo "✅ Vault is initialized"
    break
  fi
  echo "Waiting for Vault initialization... ($i/60)"
  sleep 10
done

# Wait for ESO
echo "Waiting for External Secrets Operator..."
kubectl wait --for=condition=ready --timeout=300s -n flux-system helmrelease/external-secrets 2>/dev/null || {
  echo "⚠️  ESO not ready yet"
  kubectl get helmrelease external-secrets -n flux-system 2>/dev/null || echo "ESO HelmRelease not found"
}

# Wait for cert-manager-env-config secret to be created by VaultStaticSecret
echo "Waiting for cert-manager credentials from Vault..."
for i in {1..60}; do
  if kubectl get secret cert-manager-env-config -n flux-system >/dev/null 2>&1; then
    echo "✅ cert-manager credentials secret created"
    break
  fi
  echo "Waiting for VaultStaticSecret to create cert-manager-env-config... ($i/60)"
  sleep 5
done

# Wait for other infrastructure
echo "Waiting for remaining infrastructure..."
kubectl wait --for=condition=ready --timeout=300s -n flux-system helmrelease/cert-manager 2>/dev/null || echo "⚠️  cert-manager not ready yet"
kubectl wait --for=condition=ready --timeout=300s -n flux-system helmrelease/haproxy-ingress 2>/dev/null || echo "⚠️  HAProxy not ready yet"
kubectl wait --for=condition=ready --timeout=300s -n flux-system helmrelease/cloudnative-pg 2>/dev/null || echo "⚠️  CloudNativePG not ready yet"
kubectl wait --for=condition=ready --timeout=300s -n flux-system helmrelease/rook-ceph 2>/dev/null || echo "⚠️  Rook-Ceph not ready yet"

echo ""
echo "🔍 Infrastructure status summary:"
echo "================================"
echo "Platform Foundation:"
kubectl get kustomization -n flux-system 2>/dev/null | grep -E 'NAME|platform-foundation' || echo "No platform-foundation found"
echo ""
echo "Infrastructure Layers:"
kubectl get kustomization -n flux-system 2>/dev/null | grep -E 'NAME|security|serverless|data-cache|ml-serving|data-storage' || echo "No infrastructure layers found"
echo ""
echo "HelmReleases:"
kubectl get helmrelease -n flux-system 2>/dev/null || echo "No HelmReleases found"
echo ""
echo "Application deployment status:"
kubectl get kustomization -n flux-system apps 2>/dev/null || echo "⚠️  Applications kustomization not yet deployed"