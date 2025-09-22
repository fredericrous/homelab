resource "null_resource" "flux_bootstrap" {
  count = var.configure_talos ? 1 : 0

  depends_on = [
    local_file.kubeconfig,
    null_resource.cilium_bootstrap
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG=${abspath(local_file.kubeconfig[0].filename)}

      echo "🚀 Bootstrapping FluxCD..."
      
      # Check if flux is already installed
      if kubectl get ns flux-system >/dev/null 2>&1; then
        echo "✅ FluxCD is already installed"
        exit 0
      fi

      # Install flux CLI if not present
      if ! command -v flux &> /dev/null; then
        echo "Installing flux CLI..."
        curl -s https://fluxcd.io/install.sh | sudo bash
      fi

      # Bootstrap flux
      flux bootstrap github \
        --owner=fredericrous \
        --repository=homelab \
        --branch=main \
        --path=clusters/homelab/flux-system \
        --personal \
        --token-auth

      echo "⏳ Waiting for Flux to be ready..."
      kubectl wait --for=condition=ready --timeout=300s -n flux-system pod -l app.kubernetes.io/name=source-controller
      kubectl wait --for=condition=ready --timeout=300s -n flux-system pod -l app.kubernetes.io/name=kustomize-controller

      echo "🔐 Creating vault-transit-token secret..."
      cd ${path.module}/..
      ./scripts/bootstrap-vault-transit-secret.sh
    EOT
  }

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}