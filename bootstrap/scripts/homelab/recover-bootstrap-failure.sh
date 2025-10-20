#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
KUBECONFIG_PATH="${ROOT_DIR}/kubeconfig"
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

# Recovery operations
RECOVERY_STEPS=0

recovery_step() {
  local step_name="$1"
  local recovery_command="$2"
  local success_message="$3"
  
  ((RECOVERY_STEPS++))
  log_info "Recovery Step $RECOVERY_STEPS: $step_name"
  
  if eval "$recovery_command" >/dev/null 2>&1; then
    log_success "$success_message"
    return 0
  else
    log_error "Failed: $step_name"
    return 1
  fi
}

# Diagnose current state
diagnose_system() {
  log_info "🔍 Diagnosing current system state..."
  
  # Check cluster accessibility
  if kubectl --kubeconfig="$KUBECONFIG_PATH" get nodes >/dev/null 2>&1; then
    log_success "Homelab cluster is accessible"
    
    # Check FluxCD state
    if kubectl --kubeconfig="$KUBECONFIG_PATH" get namespace flux-system >/dev/null 2>&1; then
      log_success "FluxCD namespace exists"
      
      # Check controllers
      local controllers_ready=0
      for controller in source-controller kustomize-controller helm-controller; do
        if kubectl --kubeconfig="$KUBECONFIG_PATH" get deployment -n flux-system "$controller" >/dev/null 2>&1; then
          if kubectl --kubeconfig="$KUBECONFIG_PATH" get deployment -n flux-system "$controller" -o jsonpath='{.status.readyReplicas}' | grep -q '^1$'; then
            log_success "$controller is ready"
            ((controllers_ready++))
          else
            log_warning "$controller exists but not ready"
          fi
        else
          log_warning "$controller is missing"
        fi
      done
      
      if [[ $controllers_ready -eq 3 ]]; then
        log_success "All FluxCD controllers are healthy"
      else
        log_warning "Some FluxCD controllers need attention"
      fi
    else
      log_warning "FluxCD namespace does not exist"
    fi
    
    # Check Istio state
    if kubectl --kubeconfig="$KUBECONFIG_PATH" get namespace istio-system >/dev/null 2>&1; then
      log_success "Istio namespace exists"
      
      if kubectl --kubeconfig="$KUBECONFIG_PATH" get pods -n istio-system -l app=istiod --field-selector=status.phase=Running | grep -q Running; then
        log_success "Istio control plane is running"
      else
        log_warning "Istio control plane is not ready"
      fi
    else
      log_warning "Istio namespace does not exist"
    fi
  else
    log_error "Cannot access homelab cluster"
  fi
  
  # Check NAS cluster
  if kubectl --kubeconfig="$NAS_KUBECONFIG_PATH" get nodes >/dev/null 2>&1; then
    log_success "NAS cluster is accessible"
  else
    log_warning "Cannot access NAS cluster"
  fi
}

# Recovery procedures
recover_fluxcd() {
  log_info "🔧 Recovering FluxCD..."
  
  # Check if namespace exists but controllers are missing
  if kubectl --kubeconfig="$KUBECONFIG_PATH" get namespace flux-system >/dev/null 2>&1; then
    log_info "FluxCD namespace exists, checking controllers..."
    
    # Force recreation of failed controllers
    for controller in source-controller kustomize-controller helm-controller; do
      if ! kubectl --kubeconfig="$KUBECONFIG_PATH" get deployment -n flux-system "$controller" >/dev/null 2>&1; then
        log_warning "$controller missing, will be recreated by bootstrap"
      fi
    done
  else
    log_info "FluxCD namespace missing, full bootstrap needed"
  fi
  
  recovery_step "Clean up stale FluxCD resources" \
    "kubectl --kubeconfig='$KUBECONFIG_PATH' delete gitrepository --all -n flux-system --ignore-not-found=true && kubectl --kubeconfig='$KUBECONFIG_PATH' delete kustomization --all -n flux-system --ignore-not-found=true" \
    "Stale FluxCD resources cleaned up"
}

recover_secrets() {
  log_info "🔐 Recovering secrets..."
  
  # Recreate transit token secret
  recovery_step "Recreate vault transit token secret" \
    "kubectl --kubeconfig='$KUBECONFIG_PATH' delete secret vault-transit-token -n vault --ignore-not-found=true && cd '$SCRIPT_DIR' && ./bootstrap-vault-transit-secret.sh" \
    "Vault transit token secret recreated"
  
  # Recreate cluster vars secret  
  recovery_step "Recreate cluster variables secret" \
    "kubectl --kubeconfig='$KUBECONFIG_PATH' delete secret cluster-vars -n flux-system --ignore-not-found=true && cd '$SCRIPT_DIR' && ./bootstrap-cluster-vars.sh" \
    "Cluster variables secret recreated"
  
  # Recreate cross-cluster secret
  recovery_step "Recreate cross-cluster remote secret" \
    "kubectl --kubeconfig='$KUBECONFIG_PATH' delete secret istio-remote-secret-nas -n istio-system --ignore-not-found=true && cd '$SCRIPT_DIR' && ./ensure-nas-remote-secret.sh" \
    "Cross-cluster remote secret recreated"
}

recover_istio() {
  log_info "🕸️  Recovering Istio..."
  
  # Check if istiod is stuck
  if kubectl --kubeconfig="$KUBECONFIG_PATH" get pods -n istio-system -l app=istiod | grep -E "Error|CrashLoopBackOff|Pending"; then
    recovery_step "Restart failed istiod pods" \
      "kubectl --kubeconfig='$KUBECONFIG_PATH' delete pods -n istio-system -l app=istiod" \
      "Istiod pods restarted"
  fi
  
  # Check east-west gateway
  if kubectl --kubeconfig="$KUBECONFIG_PATH" get pods -n istio-system -l istio=eastwestgateway | grep -E "Error|CrashLoopBackOff|Pending"; then
    recovery_step "Restart failed east-west gateway" \
      "kubectl --kubeconfig='$KUBECONFIG_PATH' delete pods -n istio-system -l istio=eastwestgateway" \
      "East-west gateway restarted"
  fi
}

recover_network() {
  log_info "🌐 Recovering network connectivity..."
  
  # Test basic connectivity
  if ! timeout 5 bash -c "</dev/tcp/192.168.1.42/61443" 2>/dev/null; then
    log_warning "Cannot reach NAS east-west gateway - check network/firewall"
  else
    log_success "Network connectivity to NAS appears healthy"
  fi
  
  if ! timeout 5 bash -c "</dev/tcp/192.168.1.67/15443" 2>/dev/null; then
    log_warning "Cannot reach homelab east-west gateway - check service configuration"
  else
    log_success "Network connectivity to homelab appears healthy"
  fi
}

# Full recovery workflow
full_recovery() {
  log_info "🚨 Starting full bootstrap recovery..."
  
  diagnose_system
  echo ""
  
  recover_fluxcd
  echo ""
  
  recover_secrets
  echo ""
  
  recover_istio
  echo ""
  
  recover_network
  echo ""
  
  log_info "🔄 Recovery completed. Recommend running full bootstrap:"
  echo "  task homelab:bootstrap"
  echo ""
  log_info "Or just validation if issues were minor:"
  echo "  ./validate-cross-cluster-mesh.sh"
  echo "  ./smoke-test-vault-transit.sh"
}

# Specific recovery modes
recover_cross_cluster() {
  log_info "🔗 Recovering cross-cluster connectivity only..."
  
  recover_secrets
  recover_istio
  recover_network
  
  log_info "🧪 Testing cross-cluster connectivity..."
  if ./validate-cross-cluster-mesh.sh; then
    log_success "Cross-cluster recovery successful!"
  else
    log_error "Cross-cluster recovery failed - manual intervention needed"
  fi
}

# Usage
usage() {
  echo "Bootstrap Recovery Tool"
  echo ""
  echo "Usage: $0 [mode]"
  echo ""
  echo "Modes:"
  echo "  full          - Complete recovery of all components (default)"
  echo "  cross-cluster - Recover only cross-cluster connectivity"
  echo "  diagnose      - Diagnose current state without changes"
  echo ""
  echo "Examples:"
  echo "  $0                    # Full recovery"
  echo "  $0 cross-cluster      # Fix cross-cluster issues only"
  echo "  $0 diagnose           # Just check what's wrong"
}

# Main execution
main() {
  local mode="${1:-full}"
  
  case "$mode" in
    "full")
      full_recovery
      ;;
    "cross-cluster")
      recover_cross_cluster
      ;;
    "diagnose")
      diagnose_system
      ;;
    "help"|"-h"|"--help")
      usage
      ;;
    *)
      log_error "Unknown mode: $mode"
      usage
      exit 1
      ;;
  esac
}

# Set up environment
export KUBECONFIG="$KUBECONFIG_PATH"

# Run main function
main "$@"