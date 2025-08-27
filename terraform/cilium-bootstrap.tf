# Bootstrap Cilium CNI using kustomize
resource "null_resource" "cilium_bootstrap" {
  count = var.configure_talos ? 1 : 0

  depends_on = [
    local_file.kubeconfig,
    talos_machine_bootstrap.this,
    talos_cluster_kubeconfig.this
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
      kubectl kustomize ${path.module}/../manifests/core/cilium --enable-helm | kubectl apply -f -

      echo "⏳ Waiting for Cilium to be ready..."
      kubectl wait --for=condition=ready --timeout=300s -n kube-system daemonset/cilium || true

      echo "✅ Cilium CNI installed successfully"
    EOT
  }

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}
