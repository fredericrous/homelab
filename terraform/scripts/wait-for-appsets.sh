#!/bin/bash
set -e

# Parameters
KUBECONFIG="${1:?Error: KUBECONFIG path required as first argument}"
export KUBECONFIG

echo "⏳ Waiting for ApplicationSets to generate applications..."

# First, check if ArgoCD server is healthy
echo "🔍 Checking ArgoCD server health..."
if ! kubectl wait --for=condition=available --timeout=60s deployment/argocd-server -n argocd >/dev/null 2>&1; then
  echo "⚠️  ArgoCD server is not healthy, checking logs..."
  kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=10 || true
  echo ""
  echo "⚠️  ArgoCD server may have configuration issues. Run ./scripts/fix-argocd-env-vars.sh to fix."
  exit 1
fi

# Wait for bootstrap job to complete
echo "⏳ Waiting for ArgoCD bootstrap job to complete..."
BOOTSTRAP_FOUND=false
BOOTSTRAP_COMPLETED=false

if kubectl get job argocd-bootstrap -n argocd >/dev/null 2>&1; then
  BOOTSTRAP_FOUND=true
  if kubectl wait --for=condition=complete --timeout=120s job/argocd-bootstrap -n argocd; then
    echo "✅ Bootstrap job completed"
    BOOTSTRAP_COMPLETED=true
  else
    echo "⚠️  Bootstrap job did not complete in time, checking status..."
    kubectl describe job argocd-bootstrap -n argocd || true
    kubectl logs -n argocd -l job-name=argocd-bootstrap --tail=20 || true
  fi
else
  echo "⚠️  Bootstrap job not found - it may not have been created yet"
  echo "This usually means ArgoCD is still being deployed. Exiting..."
  exit 0
fi

# If bootstrap job didn't complete, no point checking for root app
if [ "$BOOTSTRAP_COMPLETED" != "true" ]; then
  echo "⚠️  Bootstrap job did not complete successfully. Cannot proceed with ApplicationSet checks."
  exit 0
fi

# Wait for root application
echo "🔍 Checking for root Application..."
ROOT_APP_FOUND=false
timeout=60
elapsed=0
while ! kubectl get application root -n argocd &>/dev/null; do
  if [ $elapsed -ge $timeout ]; then
    echo "⚠️  Root application not found after ${timeout}s"
    echo "The bootstrap job should have created it. Checking bootstrap logs again..."
    kubectl logs -n argocd -l job-name=argocd-bootstrap --tail=30 || true
    echo ""
    echo "Cannot proceed without root application. Exiting..."
    exit 0
  fi
  echo "⏳ Waiting for root Application to be created..."
  sleep 5
  elapsed=$((elapsed + 5))
done

if kubectl get application root -n argocd &>/dev/null; then
  ROOT_APP_FOUND=true
  echo "✅ Root application found, waiting for sync..."
  # Wait for the root app to sync and create ApplicationSets
  echo "⏳ Waiting for root application to sync and create ApplicationSets..."
  for i in {1..12}; do
    SYNC_STATUS=$(kubectl get app root -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    HEALTH_STATUS=$(kubectl get app root -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    echo "  Root app status - Sync: $SYNC_STATUS, Health: $HEALTH_STATUS"
    
    if [ "$SYNC_STATUS" = "Synced" ]; then
      echo "✅ Root application synced"
      break
    fi
    sleep 5
  done
fi

# Only check ApplicationSets if root app exists and is synced
if [ "$ROOT_APP_FOUND" != "true" ]; then
  echo "⚠️  Cannot check ApplicationSets without root application. Exiting..."
  exit 0
fi

# Check ApplicationSet health
echo "🔍 Checking ApplicationSet health..."

# Dynamically get ApplicationSet names from the manifests
APPSET_DIR="/manifests/argocd/root"
# Handle both absolute and relative paths
if [[ "$KUBECONFIG" == /* ]]; then
    # Absolute path - extract the base directory
    BASE_DIR="$(dirname "$(dirname "$(dirname "$KUBECONFIG")")")"
else
    # Relative path - use current directory
    BASE_DIR="$(pwd)"
fi

# Find all ApplicationSet files and extract names
APPSETS=""
if [ -d "$BASE_DIR$APPSET_DIR" ]; then
    for file in "$BASE_DIR$APPSET_DIR"/applicationset-*.yaml; do
        if [ -f "$file" ]; then
            # Extract name from filename (remove path and extension)
            appset_name=$(basename "$file" .yaml | sed 's/^applicationset-//')
            APPSETS="$APPSETS $appset_name"
        fi
    done
fi

# Fallback to known ApplicationSets if directory not found
if [ -z "$APPSETS" ]; then
    echo "⚠️  Could not find ApplicationSet files, using known defaults..."
    APPSETS="core apps harbor stremio"
fi

echo "📋 Found ApplicationSets:$APPSETS"

# First check if ANY ApplicationSets exist
echo "🔍 Checking if any ApplicationSets have been created yet..."
APPSET_COUNT=$(kubectl get applicationsets -n argocd --no-headers 2>/dev/null | wc -l || echo "0")
if [ "$APPSET_COUNT" -eq 0 ]; then
    echo "⚠️  No ApplicationSets found yet. Waiting for root application to create them..."
    # Give it a bit more time
    for i in {1..6}; do
        APPSET_COUNT=$(kubectl get applicationsets -n argocd --no-headers 2>/dev/null | wc -l || echo "0")
        if [ "$APPSET_COUNT" -gt 0 ]; then
            echo "✅ Found $APPSET_COUNT ApplicationSet(s)"
            break
        fi
        echo "  Still no ApplicationSets... ($i/6)"
        sleep 5
    done
    
    if [ "$APPSET_COUNT" -eq 0 ]; then
        echo "❌ No ApplicationSets created after 30s. The root application may have issues."
        echo "Checking root application status again..."
        kubectl get app root -n argocd -o yaml | grep -A5 -B5 "status:" || true
        echo ""
        echo "⚠️  Proceeding anyway - ApplicationSets may be created later"
        # Don't exit - let the script continue to at least create some basic apps
    fi
fi

for appset in $APPSETS; do
    echo "📋 Checking ApplicationSet: $appset"
    
    # Wait for ApplicationSet to exist
    timeout=30  # Reduced from 60s since we already did initial wait
    elapsed=0
    while ! kubectl get applicationset $appset -n argocd &>/dev/null; do
        if [ $elapsed -ge $timeout ]; then
            echo "⚠️  ApplicationSet $appset not found after ${timeout}s"
            break
        fi
        echo "⏳ Waiting for ApplicationSet $appset to be created..."
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    if kubectl get applicationset $appset -n argocd &>/dev/null; then
        # Check for critical errors (not DNS errors)
        status=$(kubectl get applicationset $appset -n argocd -o json)
        error_message=$(echo "$status" | jq -r '.status.conditions[]? | select(.type == "ErrorOccurred" and .status == "True") | .message' 2>/dev/null || echo "")
        
        if [ -n "$error_message" ]; then
            if echo "$error_message" | grep -q "duplicate key"; then
                echo "❌ CRITICAL: ApplicationSet $appset has duplicate key errors!"
                echo "   Error: $error_message"
                echo "   This must be fixed before continuing."
                exit 1
            elif echo "$error_message" | grep -q "dial tcp: lookup"; then
                echo "⚠️  ApplicationSet $appset has DNS errors (expected at this stage)"
            else
                echo "❌ ERROR: ApplicationSet $appset has errors: $error_message"
                exit 1
            fi
        fi
    fi
done

# Wait for specific apps to be created by ApplicationSets
apps="vault cert-manager external-secrets-operator stakater-reloader rook-ceph"
KUBECONFIG_PATH="$KUBECONFIG"
for app in $apps; do
  echo "🔍 Waiting for $app application..."
  timeout 120s sh -c "export KUBECONFIG='$KUBECONFIG_PATH'; until kubectl get app -n argocd $app >/dev/null 2>&1; do
    sleep 2
  done"
  
  if [ $? -eq 0 ]; then
    echo "✅ $app application created"
  else
    echo "⚠️  Warning: $app application not found after timeout"
  fi
done

echo "📋 Current applications:"
kubectl get app -n argocd --no-headers | awk '{print "  - " $1}'

echo "✅ Proceeding with core services bootstrap"