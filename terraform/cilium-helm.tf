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

# The helm_release resource with wait=true already ensures Cilium is healthy
# No need for additional verification