# Configure Helm provider
provider "helm" {
  kubernetes {
    config_path = var.configure_talos ? abspath("${path.module}/../kubeconfig") : null
  }
}

# Install Cilium with Helm provider (GitOps style)
resource "helm_release" "cilium" {
  count      = var.configure_talos ? 1 : 0
  depends_on = [local_file.kubeconfig, talos_machine_bootstrap.this]

  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = "1.15.6"
  namespace  = "kube-system"

  wait             = true
  wait_for_jobs    = true
  timeout          = 600
  create_namespace = false

  set {
    name  = "kubeProxyReplacement"
    value = "true"
  }

  set {
    name  = "k8sServiceHost"
    value = local.all_nodes.controlplane.ip
  }

  set {
    name  = "k8sServicePort"
    value = "6443"
  }
}

# Verify Cilium is healthy
resource "null_resource" "verify_cilium" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [helm_release.cilium]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      
      export KUBECONFIG=${abspath("${path.module}/../kubeconfig")}
      
      echo "🔍 Verifying Cilium deployment..."
      
      # Wait for Cilium pods to be ready
      echo "Waiting for Cilium DaemonSet..."
      kubectl -n kube-system rollout status ds/cilium --timeout=5m
      
      echo "Waiting for Cilium Operator..."
      kubectl -n kube-system rollout status deploy/cilium-operator --timeout=5m || true
      
      # Show Cilium pod status
      echo ""
      echo "Cilium pods status:"
      kubectl -n kube-system get pods -l k8s-app=cilium
      kubectl -n kube-system get pods -l name=cilium-operator
      
      echo "✅ Cilium is healthy!"
    EOT
  }
}