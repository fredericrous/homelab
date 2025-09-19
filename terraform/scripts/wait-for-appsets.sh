#!/bin/bash
set -e

# Parameters
KUBECONFIG="${1:?Error: KUBECONFIG path required as first argument}"
export KUBECONFIG

echo "⏳ Waiting for ApplicationSets to generate applications..."

# First, check if ArgoCD server is healthy
echo "🔍 Checking ArgoCD server health..."
if ! kubectl wait --for=condition=available --timeout=30s deployment/argocd-server -n argocd >/dev/null 2>&1; then
  echo "⚠️  ArgoCD server is not healthy, checking logs..."
  kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=10 || true
  echo ""
  echo "⚠️  ArgoCD server may have configuration issues. Run ./scripts/fix-argocd-env-vars.sh to fix."
  exit 1
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

for appset in $APPSETS; do
    echo "📋 Checking ApplicationSet: $appset"
    
    # Wait for ApplicationSet to exist
    timeout=60
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