#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NAS_KUBECONFIG_DEFAULT="${ROOT_DIR}/infrastructure/nas/kubeconfig.yaml"
NAS_KUBECONFIG_PATH="${NAS_KUBECONFIG:-${NAS_KUBECONFIG_DEFAULT}}"

# Load common functions and configuration
source "${SCRIPT_DIR}/lib/common.sh"

# Initialize common functions and load config
init_common

# Temporary files for secure handling
TEMP_KUBECONFIG=""
TEMP_FILES=()

# Enhanced cleanup registration
cleanup_validation() {
  log_debug "Cleaning up validation temporary files"
  for temp_file in "${TEMP_FILES[@]}"; do
    [[ -f "$temp_file" ]] && rm -f "$temp_file"
  done
  [[ -n "$TEMP_KUBECONFIG" && -f "$TEMP_KUBECONFIG" ]] && rm -f "$TEMP_KUBECONFIG"
}

# Set up comprehensive cleanup
setup_cleanup
add_cleanup cleanup_validation

# Check prerequisites
validate_prerequisites() {
  log_info "🔍 Validating prerequisites..."
  
  validate_step "kubectl available" \
    "command -v kubectl" \
    "kubectl is required but not installed"
  
  validate_step "istioctl available" \
    "command -v istioctl" \
    "istioctl is required but not installed"
  
  validate_step "Homelab cluster accessible" \
    "kubectl get nodes" \
    "Cannot access homelab cluster - check KUBECONFIG"
  
  validate_step "NAS kubeconfig exists" \
    "test -f '$NAS_KUBECONFIG_PATH'" \
    "NAS kubeconfig not found at $NAS_KUBECONFIG_PATH"
  
  validate_step "NAS cluster accessible" \
    "kubectl --kubeconfig='$NAS_KUBECONFIG_PATH' get nodes" \
    "Cannot access NAS cluster - check if it's running"
}

# Validate Istio components with proper readiness checks
validate_istio_components() {
  log_info "🕸️  Validating Istio components..."
  
  # Homelab Istio - use proper readiness checks instead of just Running
  validate_step "Homelab istiod ready" \
    "wait_for_pods_ready istio-system 'app=istiod' 30 'homelab istiod'" \
    "Homelab istiod is not ready - check logs: kubectl logs -n istio-system -l app=istiod"
  
  validate_step "Homelab east-west gateway ready" \
    "wait_for_pods_ready istio-system 'istio=eastwestgateway' 30 'homelab east-west gateway'" \
    "Homelab east-west gateway is not ready - check service: kubectl get svc -n istio-system istio-eastwestgateway"
  
  # Verify homelab istiod is actually serving
  validate_step "Homelab istiod API accessible" \
    "kubectl exec -n istio-system deploy/istiod -- curl -s localhost:15014/ready | grep -q 'ready'" \
    "Homelab istiod API is not responding" \
    true  # Warning only
  
  # NAS Istio with better error context
  validate_step "NAS istiod ready" \
    "kubectl --kubeconfig='$NAS_KUBECONFIG_PATH' wait --for=condition=Ready pod -l app=istiod -n istio-system --timeout=30s" \
    "NAS istiod is not ready - check NAS cluster status and istiod logs"
  
  validate_step "NAS east-west gateway ready" \
    "kubectl --kubeconfig='$NAS_KUBECONFIG_PATH' wait --for=condition=Ready pod -l istio=eastwestgateway -n istio-system --timeout=30s" \
    "NAS east-west gateway is not ready - check NodePort configuration for port ${NAS_EASTWEST_PORT}"
  
  # Verify cross-cluster discovery is working
  validate_step "Homelab can discover NAS network" \
    "istioctl proxy-config cluster deploy/istiod.istio-system | grep -q '${NAS_IP}'" \
    "Homelab istiod cannot discover NAS cluster endpoints" \
    true  # Warning only - might take time to sync
}

# Validate remote secrets with enhanced security
validate_remote_secrets() {
  log_info "🔐 Validating remote secrets..."
  
  validate_step "NAS remote secret exists in homelab" \
    "kubectl get secret istio-remote-secret-nas -n istio-system" \
    "Remote secret for NAS cluster not found in homelab - run: ./ensure-nas-remote-secret.sh"
  
  validate_step "Remote secret has valid kubeconfig" \
    "kubectl get secret istio-remote-secret-nas -n istio-system -o jsonpath='{.data.nas}' | base64 -d | grep -q 'kind: Config'" \
    "Remote secret does not contain valid kubeconfig - secret may be corrupted"
  
  # Test remote secret connectivity with secure temporary file handling
  TEMP_KUBECONFIG=$(create_secure_temp_file "kubeconfig")
  TEMP_FILES+=("$TEMP_KUBECONFIG")
  
  log_debug "Extracting kubeconfig from remote secret for testing"
  if kubectl get secret istio-remote-secret-nas -n istio-system -o jsonpath='{.data.nas}' | base64 -d > "$TEMP_KUBECONFIG" 2>/dev/null; then
    validate_step "Remote secret can access NAS cluster" \
      "kubectl --kubeconfig='$TEMP_KUBECONFIG' get nodes --request-timeout=10s" \
      "Remote secret cannot access NAS cluster - check service account permissions and network connectivity"
    
    # Verify the service account has proper permissions
    validate_step "Remote secret has proper RBAC permissions" \
      "kubectl --kubeconfig='$TEMP_KUBECONFIG' auth can-i get pods --all-namespaces" \
      "Remote secret service account lacks necessary permissions for service discovery" \
      true  # Warning only
  else
    log_error "Failed to extract kubeconfig from remote secret"
    ((VALIDATION_ERRORS++))
  fi
}

# Validate service discovery
validate_service_discovery() {
  log_info "🔍 Validating service discovery..."
  
  # Check if istiod can see remote endpoints
  validate_step "Istio proxy status healthy" \
    "istioctl proxy-status | grep -v 'STALE\|NOT SENT'" \
    "Some Istio proxies have stale configuration" \
    true  # Warning only
  
  # Check for NAS services in homelab discovery
  validate_step "NAS services discoverable from homelab" \
    "kubectl get endpointslices --all-namespaces | grep -q nas" \
    "No NAS services found in homelab service discovery" \
    true  # Warning only initially
}

# Validate network connectivity with configuration management
validate_network_connectivity() {
  log_info "🌐 Validating network connectivity..."
  
  # Test east-west gateway service configuration
  validate_step "Homelab east-west gateway service configured" \
    "kubectl get svc istio-eastwestgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' | grep -q '$HOMELAB_IP'" \
    "Homelab east-west gateway does not have expected IP ($HOMELAB_IP) - check LoadBalancer configuration"
  
  validate_step "NAS east-west gateway NodePort configured" \
    "kubectl --kubeconfig='$NAS_KUBECONFIG_PATH' get svc istio-eastwestgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name==\"tls\")].nodePort}' | grep -q '$NAS_EASTWEST_PORT'" \
    "NAS east-west gateway does not have expected NodePort ($NAS_EASTWEST_PORT) - check service configuration"
  
  # Test actual network connectivity with retry logic
  validate_step "TCP connectivity to NAS east-west gateway" \
    "test_network_connectivity '$NAS_IP' '$NAS_EASTWEST_PORT' 'tcp' '$NETWORK_TIMEOUT'" \
    "Cannot establish TCP connection to NAS east-west gateway at $NAS_IP:$NAS_EASTWEST_PORT - check firewall/network routing" \
    true  # Warning only - network might be restricted
  
  validate_step "TCP connectivity to homelab east-west gateway" \
    "test_network_connectivity '$HOMELAB_IP' '$HOMELAB_EASTWEST_PORT' 'tcp' '$NETWORK_TIMEOUT'" \
    "Cannot establish TCP connection to homelab east-west gateway at $HOMELAB_IP:$HOMELAB_EASTWEST_PORT - check service configuration" \
    true  # Warning only
  
  # Test Istio-specific connectivity (mTLS)
  validate_step "Istio mTLS connectivity between clusters" \
    "istioctl proxy-config endpoints deploy/istiod.istio-system | grep -q '$NAS_IP'" \
    "Istio cannot establish mTLS connections to NAS cluster - check certificates and cross-cluster discovery" \
    true  # Warning only - might take time to establish
}

# Validate DNS anchor service
validate_dns_anchor() {
  log_info "🏷️  Validating DNS anchor service..."
  
  validate_step "Vault DNS anchor service exists" \
    "kubectl get service vault-vault-nas -n vault" \
    "Vault DNS anchor service not found"
  
  validate_step "DNS anchor is headless service" \
    "kubectl get service vault-vault-nas -n vault -o jsonpath='{.spec.clusterIP}' | grep -q 'None'" \
    "DNS anchor service should be headless (clusterIP: None)"
}

# Test vault connectivity 
validate_vault_connectivity() {
  log_info "🔐 Validating vault connectivity..."
  
  # Check if vault pod exists in homelab
  validate_step "Homelab vault pod exists" \
    "kubectl get pods -n vault -l app.kubernetes.io/name=vault | grep -q vault" \
    "Homelab vault pod not found" \
    true  # Warning only - might not be deployed yet
  
  # Check if NAS vault is accessible
  validate_step "NAS vault accessible" \
    "kubectl --kubeconfig='$NAS_KUBECONFIG_PATH' get pods -n vault -l app.kubernetes.io/name=vault | grep -q vault" \
    "NAS vault pod not found"
  
  # Test DNS resolution from homelab to NAS vault
  validate_step "Can resolve vault-vault-nas DNS" \
    "kubectl run dns-test --image=busybox --rm -it --restart=Never -- nslookup vault-vault-nas.vault.svc.cluster.local" \
    "Cannot resolve vault-vault-nas.vault.svc.cluster.local from homelab cluster" \
    true  # Warning only
}

# Main validation flow with enhanced error handling
main() {
  echo "🧪 Cross-Cluster Mesh Validation Starting..."
  echo "=============================================="
  log_info "Using configuration: Homelab($HOMELAB_IP) ↔ NAS($NAS_IP)"
  log_info "Network timeout: ${NETWORK_TIMEOUT}s, Validation timeout: ${VALIDATION_TIMEOUT}s"
  echo ""
  
  # Run validations with proper error handling
  local validation_steps=(
    "validate_prerequisites"
    "validate_istio_components"
    "validate_remote_secrets"
    "validate_service_discovery"
    "validate_network_connectivity"
    "validate_dns_anchor"
    "validate_vault_connectivity"
  )
  
  for step in "${validation_steps[@]}"; do
    log_info "Running validation step: $step"
    if ! $step; then
      log_warning "Validation step failed: $step"
      if [[ "$CLEANUP_ON_FAILURE" == "true" ]]; then
        log_info "Running cleanup due to failure..."
        cleanup_validation
      fi
    fi
    echo ""
  done
  
  # Generate comprehensive summary
  print_summary
  local summary_exit_code=$?
  
  if [[ $summary_exit_code -eq 0 ]]; then
    log_success "Cross-cluster mesh validation completed successfully!"
    
    # Save metrics if enabled
    if [[ "$METRICS_ENABLED" == "true" ]]; then
      log_info "Validation metrics saved to: $METRICS_FILE"
    fi
  else
    log_error "Cross-cluster mesh validation failed!"
    echo ""
    echo "🔧 Troubleshooting recommendations:"
    echo "  1. Check cluster status: kubectl get nodes && kubectl --kubeconfig=$NAS_KUBECONFIG_PATH get nodes"
    echo "  2. Verify Istio health: kubectl get pods -n istio-system"
    echo "  3. Test network connectivity: nc -zv $NAS_IP $NAS_EASTWEST_PORT"
    echo "  4. Check Istio logs: kubectl logs -n istio-system -l app=istiod --tail=50"
    echo "  5. Run recovery: ./recover-bootstrap-failure.sh cross-cluster"
    echo "  6. For detailed diagnostics: DEBUG_MODE=true $0"
  fi
  
  exit $summary_exit_code
}

# Run main function
main "$@"