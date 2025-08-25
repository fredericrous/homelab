# Deploy ArgoCD with Helm provider
resource "helm_release" "argocd" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [
    null_resource.wait_nodes_ready,
    null_resource.helm_repos
  ]

  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.7.12"
  namespace        = "argocd"
  create_namespace = true

  wait          = true
  wait_for_jobs = true
  timeout       = 600

  # Server configuration
  set {
    name  = "server.extraArgs[0]"
    value = "--insecure"
  }

  # Use internal Redis (comes with ArgoCD)
  set {
    name  = "redis.enabled"
    value = "true"
  }

  # Resource limits for server
  set {
    name  = "server.resources.limits.cpu"
    value = "500m"
  }

  set {
    name  = "server.resources.limits.memory"
    value = "512Mi"
  }

  set {
    name  = "server.resources.requests.cpu"
    value = "250m"
  }

  set {
    name  = "server.resources.requests.memory"
    value = "256Mi"
  }

  # Resource limits for controller
  set {
    name  = "controller.resources.limits.cpu"
    value = "1000m"
  }

  set {
    name  = "controller.resources.limits.memory"
    value = "1Gi"
  }

  set {
    name  = "controller.resources.requests.cpu"
    value = "500m"
  }

  set {
    name  = "controller.resources.requests.memory"
    value = "512Mi"
  }

  # Resource limits for repo server
  set {
    name  = "repoServer.resources.limits.cpu"
    value = "500m"
  }

  set {
    name  = "repoServer.resources.limits.memory"
    value = "512Mi"
  }

  set {
    name  = "repoServer.resources.requests.cpu"
    value = "250m"
  }

  set {
    name  = "repoServer.resources.requests.memory"
    value = "256Mi"
  }

  # Disable Dex (we'll use external auth)
  set {
    name  = "dex.enabled"
    value = "false"
  }

  # ApplicationSet controller
  set {
    name  = "applicationSet.enabled"
    value = "true"
  }

  set {
    name  = "applicationSet.resources.limits.cpu"
    value = "500m"
  }

  set {
    name  = "applicationSet.resources.limits.memory"
    value = "512Mi"
  }

  set {
    name  = "applicationSet.resources.requests.cpu"
    value = "250m"
  }

  set {
    name  = "applicationSet.resources.requests.memory"
    value = "256Mi"
  }
}

# Verify ArgoCD is healthy
resource "null_resource" "verify_argocd" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [helm_release.argocd]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      
      export KUBECONFIG=${abspath("${path.module}/../kubeconfig")}
      
      echo "🔍 Verifying ArgoCD deployment..."
      
      # Wait for ArgoCD components
      echo "Waiting for ArgoCD Server..."
      kubectl -n argocd rollout status deploy/argocd-server --timeout=5m
      
      echo "Waiting for ArgoCD Repo Server..."
      kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=5m
      
      echo "Waiting for ArgoCD Application Controller..."
      kubectl -n argocd rollout status deploy/argocd-application-controller --timeout=5m
      
      echo "Waiting for ArgoCD ApplicationSet Controller..."
      kubectl -n argocd rollout status deploy/argocd-applicationset-controller --timeout=5m
      
      # Show ArgoCD pod status
      echo ""
      echo "ArgoCD pods status:"
      kubectl -n argocd get pods
      
      # Get initial admin password
      echo ""
      echo "📝 ArgoCD initial admin password:"
      kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
      echo ""
      echo ""
      echo "🌐 Access ArgoCD:"
      echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
      echo "  Then visit: https://localhost:8080"
      echo "  Username: admin"
      
      echo "✅ ArgoCD is healthy!"
    EOT
  }
}