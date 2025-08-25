# Wait for nodes to be ready after Cilium CNI is installed
resource "null_resource" "wait_nodes_ready" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [helm_release.cilium, null_resource.verify_cilium]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      
      export KUBECONFIG=${abspath("${path.module}/../kubeconfig")}
      
      echo "⏳ Waiting for nodes to become Ready after CNI installation..."
      
      # Wait up to 5 minutes for all nodes to be ready
      timeout=300
      elapsed=0
      interval=10
      
      while [ $elapsed -lt $timeout ]; do
        # Get node status
        ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || true)
        total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
        
        echo "Nodes ready: $ready_nodes/$total_nodes (${elapsed}s elapsed)"
        
        # Check if all nodes are ready
        if [ "$total_nodes" -gt 0 ] && [ "$ready_nodes" -eq "$total_nodes" ]; then
          echo "✅ All nodes are Ready!"
          kubectl get nodes
          exit 0
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
      done
      
      echo "❌ Timeout waiting for nodes to become Ready"
      echo "Current node status:"
      kubectl get nodes || true
      kubectl describe nodes || true
      exit 1
    EOT
  }
}