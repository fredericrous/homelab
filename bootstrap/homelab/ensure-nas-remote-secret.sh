#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NAS_KUBECONFIG_DEFAULT="${ROOT_DIR}/infrastructure/nas/kubeconfig.yaml"
NAS_KUBECONFIG_PATH="${NAS_KUBECONFIG:-${NAS_KUBECONFIG_DEFAULT}}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "❌ kubectl is required to create the Istio remote secret"
  exit 1
fi

if ! command -v istioctl >/dev/null 2>&1; then
  echo "❌ istioctl is required but not installed. This should have been installed by check-prereq"
  exit 1
fi

if [ ! -f "${KUBECONFIG:-}" ]; then
  echo "❌ Homelab cluster kubeconfig not found at path specified by KUBECONFIG environment variable"
  exit 1
fi

if [ ! -f "${NAS_KUBECONFIG_PATH}" ]; then
  cat <<EOW
❌ NAS cluster kubeconfig not found at ${NAS_KUBECONFIG_PATH}
   Make sure the NAS cluster is running and kubeconfig is available.
   You can set NAS_KUBECONFIG=<path> to override the default location.
EOW
  exit 1
fi

# Test NAS cluster connectivity before proceeding
if ! kubectl --kubeconfig="${NAS_KUBECONFIG_PATH}" get nodes >/dev/null 2>&1; then
  echo "❌ Cannot connect to NAS cluster. Ensure it's running and accessible"
  exit 1
fi

# Check if secret already exists
if kubectl -n istio-system get secret istio-remote-secret-nas >/dev/null 2>&1; then
  echo "✅ Istio remote secret for NAS already exists"
  exit 0
fi

echo "🔐 Generating Istio remote secret for NAS cluster..."

# Create service account with minimal permissions in NAS cluster
echo "   Creating limited service account in NAS cluster..."
kubectl --kubeconfig="${NAS_KUBECONFIG_PATH}" create serviceaccount istio-reader-homelab --dry-run=client -o yaml | \
  kubectl --kubeconfig="${NAS_KUBECONFIG_PATH}" apply -f - >/dev/null

# Create minimal ClusterRole for cross-cluster discovery
kubectl --kubeconfig="${NAS_KUBECONFIG_PATH}" apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: istio-reader-homelab
rules:
- apiGroups: [""]
  resources: ["nodes", "pods", "services", "endpoints"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["discovery.k8s.io"]
  resources: ["endpointslices"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["networking.istio.io"]
  resources: ["*"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["security.istio.io"]
  resources: ["*"]
  verbs: ["get", "list", "watch"]
EOF

# Bind the ClusterRole to the service account
kubectl --kubeconfig="${NAS_KUBECONFIG_PATH}" create clusterrolebinding istio-reader-homelab \
  --clusterrole=istio-reader-homelab \
  --serviceaccount=default:istio-reader-homelab \
  --dry-run=client -o yaml | \
  kubectl --kubeconfig="${NAS_KUBECONFIG_PATH}" apply -f - >/dev/null

echo "   Generating remote secret with limited service account..."
TEMP_FILE="$(mktemp)"
trap 'rm -f "${TEMP_FILE}"' EXIT

# Generate the remote secret using the service account
istioctl x create-remote-secret \
  --name nas \
  --service-account istio-reader-homelab \
  --kubeconfig "${NAS_KUBECONFIG_PATH}" > "${TEMP_FILE}"

# Validate the generated secret can access the cluster
echo "   Validating remote secret connectivity..."
TEMP_KUBECONFIG="$(mktemp)"
trap 'rm -f "${TEMP_FILE}" "${TEMP_KUBECONFIG}"' EXIT

# Extract kubeconfig from the secret for testing
kubectl get secret istio-remote-secret-nas --dry-run=client -o yaml > /dev/null 2>&1 || {
  # Apply temporarily to test
  kubectl apply -f "${TEMP_FILE}" >/dev/null
  kubectl get secret istio-remote-secret-nas -o jsonpath='{.data.nas}' | base64 -d > "${TEMP_KUBECONFIG}"
  
  if ! kubectl --kubeconfig="${TEMP_KUBECONFIG}" get nodes >/dev/null 2>&1; then
    kubectl delete secret istio-remote-secret-nas >/dev/null 2>&1 || true
    echo "❌ Generated secret cannot access NAS cluster"
    exit 1
  fi
  
  # Clean up test secret - will be recreated properly
  kubectl delete secret istio-remote-secret-nas >/dev/null 2>&1 || true
}

# Ensure the namespace exists before applying the secret
kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Apply the final secret
kubectl apply -f "${TEMP_FILE}" >/dev/null

echo "✅ Istio remote secret for NAS created in homelab cluster"
echo "   • Service account: istio-reader-homelab (limited permissions)"
echo "   • Secret name: istio-remote-secret-nas"
echo "   • Cluster name: nas"