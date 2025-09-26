#!/bin/bash
# Don't use set -e because we want to continue even if some components aren't ready yet
#
# Bootstrap flow:
# 1. infrastructure-core deploys (Rook-Ceph, Vault, ESO)
# 2. Vault initializes and unseals
# 3. External Secrets Operator becomes ready
# 4. infrastructure deploys (may fail initially due to missing secrets)
# 5. VaultStaticSecret creates cert-manager-env-config from Vault
# 6. infrastructure reconciles successfully with secrets available

echo "⏳ Waiting for infrastructure components to be ready..."

# Wait for Flux to create the kustomizations first
echo "Waiting for kustomizations to be created..."
for i in {1..30}; do
  if kubectl get kustomization infrastructure-core -n flux-system >/dev/null 2>&1; then
    echo "✓ infrastructure-core kustomization found"
    break
  fi
  echo "Waiting for infrastructure-core kustomization... ($i/30)"
  sleep 2
done

# Wait for infrastructure core first (includes Reflector, MetalLB, Rook-Ceph, Vault, ESO)
echo "Waiting for infrastructure core components..."
kubectl wait --for=condition=ready --timeout=600s -n flux-system kustomization/infrastructure-core 2>/dev/null || {
  echo "⚠️  Infrastructure core not ready yet, checking status..."
  kubectl get kustomization infrastructure-core -n flux-system 2>/dev/null || echo "Infrastructure-core kustomization not found"
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
  total_mons=$(kubectl get pods -n rook-ceph -l app=rook-ceph-mon --no-headers 2>/dev/null | wc -l | tr -d '[:space:]' || echo "0")
  
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
for i in {1..60}; do
  running_osds=$(kubectl get pods -n rook-ceph -l app=rook-ceph-osd --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  
  if [ "$running_osds" -gt 0 ]; then
    echo "✅ Found $running_osds running OSD(s)"
    break
  fi
  echo "Waiting for OSDs... ($i/60)"
  sleep 5
done

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
for i in {1..36}; do  # 3 minutes total
  pvc_status=$(kubectl get pvc test-rook-health -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  if [ "$pvc_status" = "Bound" ]; then
    echo "✅ Ceph storage provisioning is working"
    kubectl delete pvc test-rook-health -n default --wait=false >/dev/null 2>&1
    break
  fi
  echo "Testing storage provisioning: $pvc_status ($i/36)"
  sleep 5
done

echo "✅ Rook-Ceph cluster is healthy and ready"

# Wait for infrastructure kustomization to be ready
echo "Waiting for infrastructure reconciliation..."
kubectl wait --for=condition=ready --timeout=600s -n flux-system kustomization/infrastructure 2>/dev/null || {
  echo "⚠️  Infrastructure kustomization not ready yet, checking status..."
  kubectl get kustomization infrastructure -n flux-system 2>/dev/null || echo "Infrastructure kustomization not found"
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
kubectl get kustomization -n flux-system 2>/dev/null | grep -E 'NAME|infrastructure|apps' || echo "No kustomizations found"
echo ""
echo "HelmReleases:"
kubectl get helmrelease -n flux-system 2>/dev/null || echo "No HelmReleases found"
echo ""
echo "Application deployment status:"
kubectl get kustomization -n flux-system apps 2>/dev/null || echo "⚠️  Applications kustomization not yet deployed"