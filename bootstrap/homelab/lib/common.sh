#!/bin/bash
# Common functions library for bootstrap scripts

# Ensure lib directory exists
mkdir -p "$(dirname "${BASH_SOURCE[0]}")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables for tracking
VALIDATION_ERRORS=0
VALIDATION_WARNINGS=0
TEST_ERRORS=0
TEST_WARNINGS=0
RECOVERY_STEPS=0

# Metrics collection
METRICS_FILE="/tmp/bootstrap-metrics-$(date +%s).json"
START_TIME=""

# Logging functions with timestamps
log_info() { 
  echo -e "${BLUE}$(date '+%H:%M:%S') ℹ️  $1${NC}"
  [[ "$DEBUG_MODE" == "true" ]] && echo "DEBUG: $1" >&2
}

log_success() { 
  echo -e "${GREEN}$(date '+%H:%M:%S') ✅ $1${NC}"
}

log_warning() { 
  echo -e "${YELLOW}$(date '+%H:%M:%S') ⚠️  $1${NC}"
}

log_error() { 
  echo -e "${RED}$(date '+%H:%M:%S') ❌ $1${NC}"
}

log_debug() {
  [[ "$DEBUG_MODE" == "true" ]] && echo -e "${BLUE}$(date '+%H:%M:%S') 🔍 DEBUG: $1${NC}" >&2
}

# Enhanced cleanup with comprehensive resource management
setup_cleanup() {
  local cleanup_functions=()
  
  # Add cleanup function
  add_cleanup() {
    cleanup_functions+=("$1")
    log_debug "Added cleanup function: $1"
  }
  
  # Enhanced cleanup that handles multiple scenarios
  comprehensive_cleanup() {
    local exit_code=$?
    log_debug "Starting comprehensive cleanup (exit code: $exit_code)"
    
    # Clean up temporary files
    for temp_file in "$@"; do
      if [[ -f "$temp_file" ]]; then
        log_debug "Removing temporary file: $temp_file"
        rm -f "$temp_file"
      fi
    done
    
    # Clean up test pods
    kubectl delete pod -l created-by=bootstrap-test --ignore-not-found=true >/dev/null 2>&1 || true
    
    # Run registered cleanup functions
    for cleanup_func in "${cleanup_functions[@]}"; do
      log_debug "Running cleanup function: $cleanup_func"
      $cleanup_func || log_warning "Cleanup function failed: $cleanup_func"
    done
    
    # Kill any background processes
    jobs -p | xargs -r kill >/dev/null 2>&1 || true
    
    log_debug "Comprehensive cleanup completed"
    exit $exit_code
  }
  
  # Set trap for multiple signals
  trap 'comprehensive_cleanup' EXIT INT TERM
}

# Retry logic with exponential backoff
retry_with_backoff() {
  local max_attempts="${MAX_RETRIES:-5}"
  local delay="${INITIAL_RETRY_DELAY:-2}"
  local command="$1"
  local description="${2:-Command}"
  
  log_debug "Starting retry loop for: $description (max attempts: $max_attempts)"
  
  for attempt in $(seq 1 $max_attempts); do
    log_debug "Attempt $attempt/$max_attempts: $description"
    
    if eval "$command" >/dev/null 2>&1; then
      log_debug "Success on attempt $attempt: $description"
      return 0
    fi
    
    if [[ $attempt -lt $max_attempts ]]; then
      log_debug "Attempt $attempt failed, waiting ${delay}s before retry"
      sleep $delay
      delay=$((delay * 2))
    fi
  done
  
  log_debug "All $max_attempts attempts failed for: $description"
  return 1
}

# Enhanced validation with proper timing and state checking
validate_step() {
  local step_name="$1"
  local validation_command="$2"
  local error_message="$3"
  local warning_only="${4:-false}"
  local timeout="${5:-$VALIDATION_TIMEOUT}"
  
  log_info "Validating: $step_name"
  START_TIME=$(date +%s%N)
  
  # Use timeout and retry for critical validations
  if timeout "$timeout" bash -c "retry_with_backoff '$validation_command' '$step_name'"; then
    local end_time=$(date +%s%N)
    local duration=$(( (end_time - START_TIME) / 1000000 ))  # Convert to milliseconds
    
    log_success "$step_name (${duration}ms)"
    record_metric "$step_name" "$duration" "success"
    return 0
  else
    local end_time=$(date +%s%N)
    local duration=$(( (end_time - START_TIME) / 1000000 ))
    
    if [[ "$warning_only" == "true" ]]; then
      log_warning "$error_message (${duration}ms)"
      record_metric "$step_name" "$duration" "warning"
      ((VALIDATION_WARNINGS++))
      return 1
    else
      log_error "$error_message (${duration}ms)"
      record_metric "$step_name" "$duration" "error"
      ((VALIDATION_ERRORS++))
      return 1
    fi
  fi
}

# Enhanced test runner with better error context
run_test() {
  local test_name="$1"
  local test_command="$2"
  local error_message="$3"
  local warning_only="${4:-false}"
  local timeout="${5:-$VALIDATION_TIMEOUT}"
  
  log_info "Testing: $test_name"
  START_TIME=$(date +%s%N)
  
  # Capture both stdout and stderr for better error context
  local output_file=$(mktemp)
  local error_file=$(mktemp)
  
  if timeout "$timeout" bash -c "$test_command" >"$output_file" 2>"$error_file"; then
    local end_time=$(date +%s%N)
    local duration=$(( (end_time - START_TIME) / 1000000 ))
    
    log_success "$test_name (${duration}ms)"
    record_metric "$test_name" "$duration" "success"
    
    # Cleanup
    rm -f "$output_file" "$error_file"
    return 0
  else
    local end_time=$(date +%s%N)
    local duration=$(( (end_time - START_TIME) / 1000000 ))
    local exit_code=$?
    
    # Provide detailed error context
    local detailed_error="$error_message"
    if [[ -s "$error_file" ]]; then
      detailed_error="$error_message. Error details: $(cat "$error_file" | head -3 | tr '\n' ' ')"
    fi
    
    if [[ "$warning_only" == "true" ]]; then
      log_warning "$detailed_error (${duration}ms, exit code: $exit_code)"
      record_metric "$test_name" "$duration" "warning"
      ((TEST_WARNINGS++))
    else
      log_error "$detailed_error (${duration}ms, exit code: $exit_code)"
      record_metric "$test_name" "$duration" "error"
      ((TEST_ERRORS++))
    fi
    
    # Cleanup
    rm -f "$output_file" "$error_file"
    return 1
  fi
}

# Secure temporary file creation
create_secure_temp_file() {
  local prefix="${1:-bootstrap}"
  local temp_file=$(mktemp -t "${prefix}.XXXXXXXX")
  chmod "${TEMP_FILE_PERMISSIONS:-600}" "$temp_file"
  log_debug "Created secure temporary file: $temp_file"
  echo "$temp_file"
}

# Metrics recording
record_metric() {
  [[ "$METRICS_ENABLED" != "true" ]] && return 0
  
  local test_name="$1"
  local duration="$2"
  local status="$3"
  
  cat >> "$METRICS_FILE" <<EOF
{"timestamp":"$(date -Iseconds)","test":"$test_name","duration":$duration,"status":"$status","script":"$(basename "$0")"}
EOF
}

# Kubernetes readiness checking with proper conditions
wait_for_pods_ready() {
  local namespace="$1"
  local selector="$2"
  local timeout="${3:-60}"
  local description="${4:-pods}"
  
  log_info "Waiting for $description to be ready..."
  
  if kubectl wait --for=condition=Ready pod -l "$selector" -n "$namespace" --timeout="${timeout}s" >/dev/null 2>&1; then
    log_success "$description are ready"
    return 0
  else
    log_error "$description failed to become ready within ${timeout}s"
    
    # Provide diagnostic information
    log_info "Pod status for debugging:"
    kubectl get pods -l "$selector" -n "$namespace" -o wide || true
    kubectl describe pods -l "$selector" -n "$namespace" | grep -A 5 -B 5 "Events:" || true
    
    return 1
  fi
}

# Network connectivity testing with protocol awareness
test_network_connectivity() {
  local host="$1"
  local port="$2"
  local protocol="${3:-tcp}"
  local timeout="${4:-$NETWORK_TIMEOUT}"
  local description="${5:-$host:$port}"
  
  log_debug "Testing network connectivity: $description ($protocol)"
  
  case "$protocol" in
    "tcp")
      if timeout "$timeout" bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
        log_success "TCP connectivity to $description"
        return 0
      else
        log_error "Cannot establish TCP connection to $description"
        return 1
      fi
      ;;
    "http")
      if timeout "$timeout" curl -s -o /dev/null "http://$host:$port" 2>/dev/null; then
        log_success "HTTP connectivity to $description"
        return 0
      else
        log_error "Cannot establish HTTP connection to $description"
        return 1
      fi
      ;;
    *)
      log_error "Unknown protocol: $protocol"
      return 1
      ;;
  esac
}

# Load configuration with validation
load_config() {
  local config_file="${1:-$(dirname "${BASH_SOURCE[0]}")/../config.env}"
  
  if [[ -f "$config_file" ]]; then
    log_debug "Loading configuration from: $config_file"
    source "$config_file"
    
    # Validate required configuration
    local required_vars=("HOMELAB_IP" "NAS_IP" "VALIDATION_TIMEOUT")
    for var in "${required_vars[@]}"; do
      if [[ -z "${!var:-}" ]]; then
        log_error "Required configuration variable not set: $var"
        return 1
      fi
    done
    
    log_debug "Configuration loaded successfully"
  else
    log_warning "Configuration file not found: $config_file"
    log_info "Using default configuration values"
  fi
}

# Summary reporting
print_summary() {
  local total_errors=$((VALIDATION_ERRORS + TEST_ERRORS))
  local total_warnings=$((VALIDATION_WARNINGS + TEST_WARNINGS))
  
  echo ""
  echo "=============================================="
  echo "📊 Summary Report"
  echo "=============================================="
  
  if [[ $total_errors -eq 0 && $total_warnings -eq 0 ]]; then
    log_success "All checks passed! System is healthy."
    return 0
  elif [[ $total_errors -eq 0 ]]; then
    log_warning "Completed with $total_warnings warnings."
    log_info "System is functional but may have minor issues."
    return 0
  else
    log_error "Failed with $total_errors errors and $total_warnings warnings."
    log_error "System requires attention before production use."
    return 1
  fi
}

# Initialize common functions
init_common() {
  # Load configuration
  load_config
  
  # Set up metrics
  if [[ "$METRICS_ENABLED" == "true" ]]; then
    echo "[]" > "$METRICS_FILE"
    log_debug "Metrics collection enabled: $METRICS_FILE"
  fi
  
  # Enable debug mode if requested
  if [[ "$DEBUG_MODE" == "true" ]]; then
    log_debug "Debug mode enabled"
    set -x
  fi
}

# Export functions for use in other scripts
export -f log_info log_success log_warning log_error log_debug
export -f setup_cleanup retry_with_backoff validate_step run_test
export -f create_secure_temp_file record_metric wait_for_pods_ready
export -f test_network_connectivity load_config print_summary init_common