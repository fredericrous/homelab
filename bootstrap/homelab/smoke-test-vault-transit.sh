#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NAS_KUBECONFIG_DEFAULT="${ROOT_DIR}/infrastructure/nas/kubeconfig.yaml"
NAS_KUBECONFIG_PATH="${NAS_KUBECONFIG:-${NAS_KUBECONFIG_DEFAULT}}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

# Test tracking
TEST_ERRORS=0
TEST_WARNINGS=0

run_test() {
  local test_name="$1"
  local test_command="$2"
  local error_message="$3"
  local warning_only="${4:-false}"
  
  log_info "Testing: $test_name"
  
  if eval "$test_command" >/dev/null 2>&1; then
    log_success "$test_name"
    return 0
  else
    if [[ "$warning_only" == "true" ]]; then
      log_warning "$error_message"
      ((TEST_WARNINGS++))
      return 1
    else
      log_error "$error_message"
      ((TEST_ERRORS++))
      return 1
    fi
  fi
}

# Test NAS vault accessibility
test_nas_vault_ready() {
  log_info "🔐 Testing NAS vault readiness..."
  
  run_test "NAS vault pod running" \
    "kubectl --kubeconfig='$NAS_KUBECONFIG_PATH' get pods -n vault -l app.kubernetes.io/name=vault --field-selector=status.phase=Running | grep -q Running" \
    "NAS vault pod is not running"
  
  run_test "NAS vault service accessible" \
    "kubectl --kubeconfig='$NAS_KUBECONFIG_PATH' get svc -n vault | grep -q vault-vault-nas" \
    "NAS vault service not found"
  
  # Test vault API accessibility from NAS cluster
  run_test "NAS vault API responding" \
    "kubectl --kubeconfig='$NAS_KUBECONFIG_PATH' exec -n vault deploy/vault-vault-nas -- vault status" \
    "NAS vault API is not responding" \
    true  # Warning only - might be sealed
}

# Test DNS resolution from homelab to NAS vault
test_dns_resolution() {
  log_info "🏷️  Testing DNS resolution..."
  
  # Create test pod for DNS testing
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: dns-test-$(date +%s)
  namespace: vault
spec:
  containers:
  - name: dns-test
    image: busybox:1.35
    command: ['sleep', '300']
  restartPolicy: Never
EOF
  
  # Wait for pod to be ready
  kubectl wait --for=condition=Ready pod -l run=dns-test -n vault --timeout=60s >/dev/null 2>&1 || true
  
  # Get the latest DNS test pod
  DNS_TEST_POD=$(kubectl get pods -n vault --sort-by=.metadata.creationTimestamp | grep dns-test | tail -1 | awk '{print $1}')
  
  if [[ -n "$DNS_TEST_POD" ]]; then
    run_test "DNS resolution for vault-vault-nas" \
      "kubectl exec -n vault $DNS_TEST_POD -- nslookup vault-vault-nas.vault.svc.cluster.local" \
      "Cannot resolve vault-vault-nas.vault.svc.cluster.local"
    
    # Cleanup
    kubectl delete pod "$DNS_TEST_POD" -n vault >/dev/null 2>&1 || true
  else
    log_error "Could not create DNS test pod"
    ((TEST_ERRORS++))
  fi
}

# Test cross-cluster service connectivity 
test_cross_cluster_connectivity() {
  log_info "🌐 Testing cross-cluster connectivity..."
  
  # Test if homelab can reach NAS vault through Istio mesh
  run_test "Istio mesh connectivity to NAS vault" \
    "kubectl run connectivity-test --image=curlimages/curl --rm -it --restart=Never -- curl -s -m 10 http://vault-vault-nas.vault.svc.cluster.local:8200/v1/sys/health" \
    "Cannot reach NAS vault through Istio mesh" \
    true  # Warning only - vault might be sealed
}

# Test vault transit configuration
test_vault_transit_config() {
  log_info "🔑 Testing vault transit configuration..."
  
  # Check if homelab vault has transit seal configuration
  if kubectl get pods -n vault -l app.kubernetes.io/name=vault >/dev/null 2>&1; then
    run_test "Homelab vault pod exists" \
      "kubectl get pods -n vault -l app.kubernetes.io/name=vault --field-selector=status.phase=Running | grep -q Running" \
      "Homelab vault pod not running" \
      true  # Warning only - might not be deployed yet
    
    # Check vault configuration for transit seal
    run_test "Vault has transit seal configuration" \
      "kubectl get configmap vault-config -n vault -o yaml | grep -q 'vault-vault-nas.vault.svc.cluster.local'" \
      "Vault configuration does not reference NAS vault for transit unsealing" \
      true  # Warning only
  else
    log_warning "Homelab vault not deployed yet - skipping vault-specific tests"
    ((TEST_WARNINGS++))
  fi
}

# Test end-to-end transit unsealing simulation
test_transit_unsealing_flow() {
  log_info "🔓 Testing transit unsealing flow..."
  
  # Check if vault transit token secret exists
  run_test "Vault transit token secret exists" \
    "kubectl get secret vault-transit-token -n vault" \
    "Vault transit token secret not found" \
    true  # Warning only
  
  # Test if NAS vault has transit backend enabled
  if kubectl --kubeconfig="$NAS_KUBECONFIG_PATH" exec -n vault deploy/vault-vault-nas -- vault status >/dev/null 2>&1; then
    run_test "NAS vault transit backend accessible" \
      "kubectl --kubeconfig='$NAS_KUBECONFIG_PATH' exec -n vault deploy/vault-vault-nas -- vault auth -method=token" \
      "Cannot authenticate to NAS vault transit backend" \
      true  # Warning only - might need setup
  else
    log_warning "NAS vault not accessible for transit testing"
    ((TEST_WARNINGS++))
  fi
}

# Test Istio metrics and observability
test_istio_observability() {
  log_info "📊 Testing Istio observability..."
  
  run_test "Istio proxy metrics available" \
    "kubectl exec -n istio-system deploy/istiod -- curl -s localhost:15014/stats | grep -q 'cluster_outbound'" \
    "Istio proxy metrics not available" \
    true  # Warning only
  
  run_test "Cross-cluster service discovery working" \
    "istioctl proxy-config endpoints deploy/istiod.istio-system | grep -q '192.168.1.42'" \
    "Cross-cluster endpoints not discovered by Istio" \
    true  # Warning only
}

# Performance testing
test_performance() {
  log_info "⚡ Testing performance..."
  
  # Test DNS resolution latency
  start_time=$(date +%s%N)
  if kubectl run perf-test --image=busybox --rm -it --restart=Never -- nslookup vault-vault-nas.vault.svc.cluster.local >/dev/null 2>&1; then
    end_time=$(date +%s%N)
    duration=$(( (end_time - start_time) / 1000000 ))  # Convert to milliseconds
    
    if [[ $duration -lt 1000 ]]; then
      log_success "DNS resolution latency: ${duration}ms (excellent)"
    elif [[ $duration -lt 5000 ]]; then
      log_warning "DNS resolution latency: ${duration}ms (acceptable)"
      ((TEST_WARNINGS++))
    else
      log_error "DNS resolution latency: ${duration}ms (too slow)"
      ((TEST_ERRORS++))
    fi
  else
    log_error "DNS resolution performance test failed"
    ((TEST_ERRORS++))
  fi
}

# Main test flow
main() {
  echo "🧪 Vault Transit End-to-End Smoke Test"
  echo "======================================="
  
  test_nas_vault_ready
  test_dns_resolution
  test_cross_cluster_connectivity  
  test_vault_transit_config
  test_transit_unsealing_flow
  test_istio_observability
  test_performance
  
  echo ""
  echo "======================================="
  echo "🧪 Smoke Test Summary"
  echo "======================================="
  
  if [[ $TEST_ERRORS -eq 0 && $TEST_WARNINGS -eq 0 ]]; then
    log_success "All smoke tests passed! Vault transit unsealing is ready for production."
    exit 0
  elif [[ $TEST_ERRORS -eq 0 ]]; then
    log_warning "Smoke tests completed with $TEST_WARNINGS warnings."
    log_info "Vault transit unsealing should work but may have performance/observability issues."
    exit 0
  else
    log_error "Smoke tests failed with $TEST_ERRORS errors and $TEST_WARNINGS warnings."
    log_error "Vault transit unsealing is NOT ready for production use."
    echo ""
    echo "Troubleshooting steps:"
    echo "  1. Run cross-cluster validation: ./validate-cross-cluster-mesh.sh"
    echo "  2. Check NAS vault status: kubectl --kubeconfig=$NAS_KUBECONFIG_PATH get pods -n vault"
    echo "  3. Check homelab DNS: kubectl get service vault-vault-nas -n vault"
    echo "  4. Test network connectivity: nc -zv 192.168.1.42 61443"
    echo "  5. Check Istio logs: kubectl logs -n istio-system -l app=istiod"
    exit 1
  fi
}

# Run main function
main "$@"