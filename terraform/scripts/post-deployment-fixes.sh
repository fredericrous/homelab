#!/bin/bash
set -e

# Parameters
KUBECONFIG="${1:?Error: KUBECONFIG path required as first argument}"
export KUBECONFIG

echo "🔧 Running post-deployment fixes..."

# Fix 1: Ensure HAProxy client CA certificate exists
echo "🔐 Checking HAProxy client CA certificate..."
if ! kubectl get secret client-ca-cert -n haproxy-controller >/dev/null 2>&1; then
  echo "⚠️  Client CA certificate secret missing"

  # Check if CA was synced from NAS
  if kubectl get secret nas-ca-cert-temp -n vault >/dev/null 2>&1; then
    echo "📤 Creating client CA secret from NAS sync..."
    CA_CERT=$(kubectl get secret nas-ca-cert-temp -n vault -o jsonpath='{.data.ca_crt}' | base64 -d)
    
    # Create secret in vault namespace with Reflector annotations
    echo "$CA_CERT" | kubectl create secret generic client-ca-cert \
      --from-file=ca.crt=/dev/stdin \
      -n vault || true
      
    # Add Reflector annotations to replicate to haproxy-controller
    kubectl annotate secret client-ca-cert -n vault \
      "reflector.v1.k8s.emberstack.com/reflection-allowed=true" \
      "reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces=haproxy-controller" \
      "reflector.v1.k8s.emberstack.com/reflection-auto-enabled=true" \
      --overwrite || true
      
    echo "✅ Client CA secret created with Reflector annotations"
  else
    echo "❌ NAS CA sync not found"
    echo "   Ensure NAS ESO sync is configured and the CA is available in Vault"
    echo "   The CA should be synced from NAS Vault at secret/pki/ca"
  fi
else
  echo "✅ Client CA certificate already exists"
fi

# Fix 2: Ensure OVH credentials are valid
echo "🌐 Checking OVH credentials..."
if kubectl get secret ovh-credentials -n cert-manager >/dev/null 2>&1; then
  # Check if they're placeholders
  APP_KEY=$(kubectl get secret ovh-credentials -n cert-manager -o jsonpath='{.data.applicationKey}' | base64 -d)
  if [ "$APP_KEY" = "placeholder" ] || [ "$APP_KEY" = "YOUR_APPLICATION_KEY" ]; then
    echo "⚠️  OVH credentials are placeholders"

    if [ -n "$CERT_MANAGER_OVH_APPLICATION_KEY" ] && [ -n "$CERT_MANAGER_OVH_APPLICATION_SECRET" ] && [ -n "$CERT_MANAGER_OVH_CONSUMER_KEY" ]; then
      echo "📤 Updating OVH credentials..."
      kubectl create secret generic ovh-credentials -n cert-manager \
        --from-literal=applicationKey="$CERT_MANAGER_OVH_APPLICATION_KEY" \
        --from-literal=applicationSecret="$CERT_MANAGER_OVH_APPLICATION_SECRET" \
        --from-literal=consumerKey="$CERT_MANAGER_OVH_CONSUMER_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -
      echo "✅ OVH credentials updated"
    else
      echo "❌ OVH credentials not provided. Set CERT_MANAGER_OVH_APPLICATION_KEY, CERT_MANAGER_OVH_APPLICATION_SECRET, and CERT_MANAGER_OVH_CONSUMER_KEY"
    fi
  else
    echo "✅ OVH credentials configured"
  fi
else
  echo "⚠️  OVH credentials secret missing"
  if [ -n "$CERT_MANAGER_OVH_APPLICATION_KEY" ] && [ -n "$CERT_MANAGER_OVH_APPLICATION_SECRET" ] && [ -n "$CERT_MANAGER_OVH_CONSUMER_KEY" ]; then
    echo "📤 Creating OVH credentials..."
    kubectl create secret generic ovh-credentials -n cert-manager \
      --from-literal=applicationKey="$CERT_MANAGER_OVH_APPLICATION_KEY" \
      --from-literal=applicationSecret="$CERT_MANAGER_OVH_APPLICATION_SECRET" \
      --from-literal=consumerKey="$CERT_MANAGER_OVH_CONSUMER_KEY" \
      --dry-run=client -o yaml | kubectl apply -f -
    echo "✅ OVH credentials created"
  fi
fi

# Fix 3: Ensure cert-manager webhook has proper permissions
echo "🔑 Checking cert-manager webhook permissions..."
if ! kubectl get role cert-manager-webhook-ovh:extension-apiserver-authentication-reader -n kube-system >/dev/null 2>&1; then
  echo "⚠️  Webhook permissions missing, applying fix..."
  kubectl apply -f ../manifests/core/cert-manager/ovh-webhook-kube-system-fix.yaml || true

  # Restart webhook pod
  kubectl delete pod -n cert-manager -l app.kubernetes.io/name=cert-manager-webhook-ovh || true
  echo "✅ Webhook permissions fixed"
else
  echo "✅ Webhook permissions configured"
fi

# Fix 4: Check if certificates are issuing
echo "📜 Checking certificate status..."
PENDING_CERTS=$(kubectl get certificate -A --no-headers | grep -v "True" | wc -l)
if [ "$PENDING_CERTS" -gt 0 ]; then
  echo "⚠️  Found $PENDING_CERTS pending certificates"

  # Check if ClusterIssuer is ready
  if kubectl get clusterissuer letsencrypt-ovh-webhook >/dev/null 2>&1; then
    ISSUER_READY=$(kubectl get clusterissuer letsencrypt-ovh-webhook -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    if [ "$ISSUER_READY" != "True" ]; then
      echo "❌ ClusterIssuer not ready. Check OVH credentials and webhook status"
    else
      echo "✅ ClusterIssuer is ready, certificates should start issuing soon"
    fi
  else
    echo "❌ ClusterIssuer not found"
  fi
else
  echo "✅ All certificates issued successfully"
fi

# Fix 5: Ensure ArgoCD is accessible
echo "🌐 Checking ArgoCD accessibility..."
if kubectl get ingress argocd-server -n argocd >/dev/null 2>&1; then
  # Check if TLS is configured
  TLS_HOST=$(kubectl get ingress argocd-server -n argocd -o jsonpath='{.spec.tls[0].hosts[0]}' 2>/dev/null)
  if [ -z "$TLS_HOST" ]; then
    echo "⚠️  ArgoCD ingress missing TLS configuration"
  else
    echo "✅ ArgoCD configured with TLS for $TLS_HOST"

    # Check certificate
    if kubectl get certificate argocd-server-tls -n argocd >/dev/null 2>&1; then
      CERT_READY=$(kubectl get certificate argocd-server-tls -n argocd -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
      if [ "$CERT_READY" = "True" ]; then
        echo "✅ ArgoCD certificate issued successfully"
      else
        echo "⚠️  ArgoCD certificate not ready yet"
      fi
    fi
  fi
else
  echo "❌ ArgoCD ingress not found"
fi

echo ""
echo "🎯 Post-deployment fixes completed"
echo ""
echo "Next steps:"
echo "1. If certificates are pending, wait a few minutes for DNS propagation"
echo "2. Access ArgoCD at https://argocd.daddyshome.fr"
echo "3. Get admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
