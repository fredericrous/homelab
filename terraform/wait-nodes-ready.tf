# Wait for all nodes to be ready after CNI deployment
resource "null_resource" "wait_nodes_ready" {
  count = var.configure_talos ? 1 : 0

  depends_on = [
    talos_machine_configuration_apply.workers,
    null_resource.argocd_bootstrap  # ArgoCD will deploy Cilium
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG=${abspath(local_file.kubeconfig[0].filename)}
      
      echo "⏳ Waiting for all nodes to be Ready..."
      for i in {1..120}; do
        NOT_READY=$(kubectl get nodes -o jsonpath='{.items[?(@.status.conditions[?(@.type=="Ready")].status!="True")].metadata.name}' | tr ' ' '\n' | grep -v '^$' || true)
        
        if [ -z "$NOT_READY" ]; then
          echo "✅ All nodes are Ready!"
          kubectl get nodes
          break
        else
          echo "Waiting for nodes: $NOT_READY ($i/120)"
          sleep 5
        fi
        
        if [ $i -eq 120 ]; then
          echo "❌ Timeout waiting for nodes to be ready"
          kubectl get nodes
          kubectl describe nodes
          exit 1
        fi
      done
      
      echo "✅ Cluster is ready for workloads!"
    EOT
  }

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}