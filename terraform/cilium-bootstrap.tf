# Bootstrap Cilium CNI using kustomize
resource "null_resource" "cilium_bootstrap" {
  count = var.configure_talos ? 1 : 0

  depends_on = [
    local_file.kubeconfig,
    null_resource.bootstrap_cluster,
    talos_cluster_kubeconfig.this,
    null_resource.dns_bootstrap,
    null_resource.sync_global_config
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG=${abspath(local_file.kubeconfig[0].filename)}

      echo "⏳ Waiting for API server to be ready..."
      for i in {1..60}; do
        if kubectl get nodes >/dev/null 2>&1; then
          echo "✅ API server is ready"
          break
        fi
        echo "Waiting for API server... ($i/60)"
        sleep 5
      done

      echo "🔍 Checking if Cilium is already installed..."
      if kubectl get daemonset -n kube-system cilium >/dev/null 2>&1; then
        echo "✅ Cilium already installed, skipping"
        exit 0
      fi

      echo "🚀 Installing Cilium CNI..."
      
      # Load control plane IP from temporary global-config.yaml
      echo "Loading control plane IP..."
      if [ -f "${path.module}/../.global-config.yaml.tmp" ]; then
        CONTROL_PLANE_IP=$(yq '.controlPlaneIP' ${path.module}/../.global-config.yaml.tmp)
        echo "Loaded control plane IP from temporary global-config.yaml"
      else
        echo "ERROR: .global-config.yaml.tmp not found - ensure sync_global_config has run"
        exit 1
      fi
      
      # Verify the control plane IP is loaded
      if [ -z "$CONTROL_PLANE_IP" ]; then
        echo "ERROR: Control plane IP not found!"
        exit 1
      fi
      echo "Using control plane IP: $CONTROL_PLANE_IP"
      
      # Direct substitution - no need for ARGO_ prefix
      
      # Create a temporary values file with substituted variables
      echo "Creating temporary values file with substituted variables..."
      TEMP_VALUES=$(mktemp)
      sed "s/PLACEHOLDER_CONTROL_PLANE_IP/$CONTROL_PLANE_IP/g" ${path.module}/../manifests/core/cilium/values.talos.yaml > "$TEMP_VALUES"
      
      # Use Helm directly to install Cilium with the substituted values
      echo "Installing Cilium with Helm..."
      helm upgrade --install cilium cilium/cilium \
        --version 1.18.1 \
        --namespace kube-system \
        --values "$TEMP_VALUES" \
        --wait
      
      # Clean up temp file
      rm -f "$TEMP_VALUES"
      
      # Verify the substitution worked
      echo "Verifying KUBERNETES_SERVICE_HOST was set correctly..."
      kubectl get ds cilium -n kube-system -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KUBERNETES_SERVICE_HOST")].value}' || echo "Failed to verify"
      
      # Remove the apply-sysctl-overwrites init container that doesn't work with Talos
      echo ""
      echo "🔧 Patching Cilium for Talos compatibility..."
      echo "Removing apply-sysctl-overwrites init container (incompatible with Talos)..."
      
      # Find the index of apply-sysctl-overwrites container
      SYSCTL_INDEX=$(kubectl get ds cilium -n kube-system -o json | jq '.spec.template.spec.initContainers | map(.name == "apply-sysctl-overwrites") | index(true)')
      
      if [ "$SYSCTL_INDEX" != "null" ]; then
        echo "Found apply-sysctl-overwrites at index $SYSCTL_INDEX, removing..."
        kubectl patch daemonset cilium -n kube-system --type='json' -p="[{\"op\": \"remove\", \"path\": \"/spec/template/spec/initContainers/$SYSCTL_INDEX\"}]"
        echo "✅ Patched Cilium DaemonSet for Talos compatibility"
      else
        echo "✅ apply-sysctl-overwrites container not found (already removed or not present)"
      fi

      echo "⏳ Waiting for Cilium to be ready..."
      
      # Wait for Cilium to be fully operational
      RETRY_COUNT=0
      MAX_RETRIES=60
      while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        echo "Checking Cilium status... ($((RETRY_COUNT+1))/$MAX_RETRIES)"
        
        # Check critical Cilium components
        OPERATOR_READY=$(kubectl get deployment -n kube-system cilium-operator -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
        CILIUM_DS_DESIRED=$(kubectl get ds -n kube-system cilium -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
        CILIUM_DS_READY=$(kubectl get ds -n kube-system cilium -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
        
        # Check for any pods in error states
        ERROR_COUNT=$(kubectl get pods -n kube-system -l k8s-app=cilium -o json 2>/dev/null | jq -r '.items[] | select(.status.phase != "Running" and .status.phase != "Succeeded") | .metadata.name' | wc -l || echo 999)
        INIT_ERROR_COUNT=$(kubectl get pods -n kube-system -l k8s-app=cilium -o json 2>/dev/null | jq -r '.items[] | select(.status.initContainerStatuses[]? | select(.state.waiting.reason == "CrashLoopBackOff" or .state.waiting.reason == "Error")) | .metadata.name' | wc -l || echo 999)
        
        echo "  Cilium Operator: $OPERATOR_READY"
        echo "  Cilium DaemonSet: $CILIUM_DS_READY/$CILIUM_DS_DESIRED ready"
        echo "  Pods with errors: $ERROR_COUNT"
        echo "  Init container errors: $INIT_ERROR_COUNT"
        
        # Show current status
        echo "  Current pod status:"
        kubectl get pods -n kube-system -o wide | grep -E "^NAME|cilium" | awk '{printf "    %-40s %-12s %-10s %s\n", $1, $2, $3, $7}' || true
        
        # Success criteria:
        # 1. Operator is Available
        # 2. If DaemonSet has desired pods, they should all be ready
        # 3. No pods in error state
        # 4. No init container errors
        # Note: During initial deployment, DaemonSet might be 0/0 if only control plane exists
        if [[ "$OPERATOR_READY" == "True" ]] && \
           [[ "$ERROR_COUNT" -eq 0 ]] && \
           [[ "$INIT_ERROR_COUNT" -eq 0 ]]; then
          if [[ "$CILIUM_DS_DESIRED" -eq 0 ]]; then
            echo "✅ Cilium is ready! (No worker nodes yet - DaemonSet is 0/0)"
            echo "   This is expected during staged deployment."
            break
          elif [[ "$CILIUM_DS_READY" -eq "$CILIUM_DS_DESIRED" ]]; then
            echo "✅ Cilium is healthy and ready!"
            break
          fi
        fi
        
        # If we detect init container errors, show detailed logs
        if [ "$INIT_ERROR_COUNT" -gt 0 ]; then
          echo "  ⚠️  Found init container errors:"
          ERROR_PODS=$(kubectl get pods -n kube-system -l k8s-app=cilium -o json | jq -r '.items[] | select(.status.initContainerStatuses[]? | select(.state.waiting.reason == "CrashLoopBackOff" or .state.waiting.reason == "Error")) | .metadata.name')
          for POD in $ERROR_PODS; do
            echo "    Pod $POD init containers:"
            kubectl get pod -n kube-system $POD -o json | jq -r '.status.initContainerStatuses[] | select(.state.waiting) | "      - \(.name): \(.state.waiting.reason) - \(.state.waiting.message // "no message")"'
            # Get the last terminated state for more info
            FAILED_CONTAINER=$(kubectl get pod -n kube-system $POD -o json | jq -r '.status.initContainerStatuses[] | select(.lastState.terminated) | .name' | head -1)
            if [ -n "$FAILED_CONTAINER" ]; then
              echo "      Last error from $FAILED_CONTAINER:"
              kubectl logs -n kube-system $POD -c $FAILED_CONTAINER --tail=3 2>/dev/null | sed 's/^/        /' || true
            fi
          done
        fi
        
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
          echo "❌ Timeout waiting for Cilium to be ready"
          echo "Final status:"
          kubectl get pods -n kube-system -o wide | grep -E "cilium"
          echo ""
          echo "Node status:"
          kubectl get nodes
          exit 1
        fi
        
        sleep 5
      done
      
      # Final verification - check if nodes became ready
      echo "🔍 Verifying cluster networking..."
      NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
      READY_COUNT=$(kubectl get nodes --no-headers | grep " Ready " | wc -l)
      echo "Nodes: $READY_COUNT/$NODE_COUNT ready"
      
      if [ "$READY_COUNT" -ne "$NODE_COUNT" ]; then
        echo "⚠️  Warning: Not all nodes are ready yet, but Cilium is healthy"
        echo "This is normal - nodes may take a moment to report ready status"
      fi
      
      kubectl get nodes
      echo "✅ Cilium CNI installed successfully"
    EOT
  }

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}
