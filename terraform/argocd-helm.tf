# Deploy ArgoCD with local-exec due to kubeconfig limitations
resource "null_resource" "argocd_install" {
  count = var.configure_talos ? 1 : 0

  depends_on = [
    local_file.kubeconfig,
    null_resource.helm_repos,
    null_resource.dns_bootstrap
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG=${abspath(local_file.kubeconfig[0].filename)}
      
      echo "🔍 Checking if ArgoCD is already installed..."
      if helm list -n argocd | grep -q "^argocd"; then
        echo "✅ ArgoCD Helm release already exists"
        # Check if it's in a failed state
        if helm status argocd -n argocd | grep -q "STATUS: failed"; then
          echo "⚠️  ArgoCD is in failed state, upgrading..."
          
          # Load external domain from .env file
          PROJECT_ROOT="$(cd "${path.module}/.." && pwd)"
          ENV_FILE="$${PROJECT_ROOT}/.env"
          if [ -f "$${ENV_FILE}" ]; then
            set -a
            source "$${ENV_FILE}"
            set +a
            EXTERNAL_DOMAIN="$${ARGO_EXTERNAL_DOMAIN:-}"
          else
            echo "ERROR: .env file not found"
            exit 1
          fi
          # Direct substitution - no need for ARGO_ prefix
          
          # Create namespace first
          echo "📦 Creating ArgoCD namespace..."
          kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
          
          # Load external domain from .env file
          echo "📦 Loading external domain..."
          PROJECT_ROOT="$(cd "${path.module}/.." && pwd)"
          ENV_FILE="$${PROJECT_ROOT}/.env"
          if [ -f "$${ENV_FILE}" ]; then
            set -a
            source "$${ENV_FILE}"
            set +a
            EXTERNAL_DOMAIN="$${ARGO_EXTERNAL_DOMAIN:-}"
            echo "Loaded from .env file"
          else
            echo "ERROR: .env file not found"
            exit 1
          fi
          # Direct substitution - no need for ARGO_ prefix
          
          # Create temporary values files with substituted variables
          TEMP_VALUES_BASE=$(mktemp)
          TEMP_VALUES_SUBSTITUTED=$(mktemp)
          cp ${path.module}/argocd-values.yaml "$TEMP_VALUES_BASE"
          sed "s/\$${ARGO_EXTERNAL_DOMAIN}/$EXTERNAL_DOMAIN/g" ${path.module}/../manifests/argocd/values.yaml > "$TEMP_VALUES_SUBSTITUTED"
          
          helm upgrade argocd argo/argo-cd \
            --version 7.7.12 \
            --namespace argocd \
            --create-namespace \
            --wait --timeout 10m \
            --values "$TEMP_VALUES_BASE" \
            --values "$TEMP_VALUES_SUBSTITUTED"
          
          rm -f "$TEMP_VALUES_BASE" "$TEMP_VALUES_SUBSTITUTED"
        else
          echo "✅ ArgoCD is already deployed and healthy"
        fi
        exit 0
      fi
      
      # Load external domain from .env file
      echo "📦 Loading external domain..."
      PROJECT_ROOT="$(cd "${path.module}/.." && pwd)"
      ENV_FILE="$${PROJECT_ROOT}/.env"
      if [ -f "$${ENV_FILE}" ]; then
        set -a
        source "$${ENV_FILE}"
        set +a
        EXTERNAL_DOMAIN="$${ARGO_EXTERNAL_DOMAIN:-}"
        echo "Loaded from .env file"
      else
        echo "ERROR: .env file not found"
        exit 1
      fi
      # Direct substitution - no need for ARGO_ prefix
      
      # Create namespace first
      echo "📦 Creating ArgoCD namespace..."
      kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
      
      # Create temporary values files with substituted variables
      echo "Creating temporary values files..."
      TEMP_VALUES_BASE=$(mktemp)
      TEMP_VALUES_SUBSTITUTED=$(mktemp)
      cp ${path.module}/argocd-values.yaml "$TEMP_VALUES_BASE"
      sed "s/\$${ARGO_EXTERNAL_DOMAIN}/$EXTERNAL_DOMAIN/g" ${path.module}/../manifests/argocd/values.yaml > "$TEMP_VALUES_SUBSTITUTED"
      
      echo "🚀 Installing ArgoCD..."
      helm install argocd argo/argo-cd \
        --version 7.7.12 \
        --namespace argocd \
        --create-namespace \
        --wait --timeout 10m \
        --values "$TEMP_VALUES_BASE" \
        --values "$TEMP_VALUES_SUBSTITUTED"
      
      # Clean up temp files
      rm -f "$TEMP_VALUES_BASE" "$TEMP_VALUES_SUBSTITUTED"
      
      echo "✅ ArgoCD installed successfully"
    EOT
  }

  # Trigger replacement if cluster is recreated
  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}

# Bootstrap ArgoCD with app-of-apps
resource "null_resource" "argocd_bootstrap" {
  count = var.configure_talos ? 1 : 0

  depends_on = [null_resource.argocd_install]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG=${abspath(local_file.kubeconfig[0].filename)}
      
      echo "⏳ Waiting for ArgoCD to be ready..."
      kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd || true
      
      echo "🚀 Bootstrapping ArgoCD with app-of-apps..."
      # Apply kustomize, but delete any existing jobs that might conflict
      kubectl delete job argocd-redis-secret-init -n argocd --ignore-not-found=true
      
      # Setup ArgoCD Vault Plugin
      echo "🔐 Setting up ArgoCD Vault Plugin..."
      # Export QNAP_VAULT_TOKEN if available from .env
      PROJECT_ROOT="$(cd "${path.module}/.." && pwd)"
      ENV_FILE="$${PROJECT_ROOT}/.env"
      if [ -f "$${ENV_FILE}" ]; then
        QNAP_VAULT_TOKEN=$(grep "^QNAP_VAULT_TOKEN=" "$${ENV_FILE}" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | sed 's/^export //')
        if [ -n "$${QNAP_VAULT_TOKEN}" ]; then
          export QNAP_VAULT_TOKEN
        fi
      fi
      ${path.module}/scripts/setup-argocd-vault-plugin.sh "${abspath(local_file.kubeconfig[0].filename)}"
      
      # Apply repository secret for homelab-values
      echo "🔑 Applying repository secret for homelab-values..."
      GITHUB_HOMELAB_VALUES_TOKEN="${var.github_homelab_values_token}"
      GITHUB_HOMELAB_VALUES_REPO="${var.github_homelab_values_repo}"
      if [ -n "$GITHUB_HOMELAB_VALUES_TOKEN" ]; then
        export GITHUB_HOMELAB_VALUES_TOKEN
        export GITHUB_HOMELAB_VALUES_REPO
        envsubst < ${path.module}/../manifests/argocd/bootstrap/repo-secret-homelab-values.yaml | kubectl apply -f -
        echo "✅ Repository secret applied"
      else
        echo "⚠️  WARNING: GITHUB_HOMELAB_VALUES_TOKEN not set, skipping repository secret"
      fi
      
      # Load external domain from .env file
      PROJECT_ROOT="$(cd "${path.module}/.." && pwd)"
      ENV_FILE="$${PROJECT_ROOT}/.env"
      if [ -f "$${ENV_FILE}" ]; then
        set -a
        source "$${ENV_FILE}"
        set +a
        EXTERNAL_DOMAIN="$${ARGO_EXTERNAL_DOMAIN:-}"
        echo "Loaded from .env file"
      else
        echo "ERROR: .env file not found"
        exit 1
      fi
      
      # Verify the external domain is loaded
      if [ -z "$EXTERNAL_DOMAIN" ]; then
        echo "ERROR: External domain not found!"
        exit 1
      fi
      echo "Using external domain: $EXTERNAL_DOMAIN"
      # Direct substitution - no need for ARGO_ prefix
      
      # Use kustomize with --enable-helm flag to process Helm charts and substitute variables
      kustomize build ${path.module}/../manifests/argocd --enable-helm | \
        sed "s/\$${ARGO_EXTERNAL_DOMAIN}/$EXTERNAL_DOMAIN/g" | \
        kubectl apply -f -
      
      # If kustomize fails, check what happened but don't fail the deployment
      if [ $? -ne 0 ]; then
        echo "⚠️  Some ArgoCD resources may have failed to apply (this is normal for CRDs)"
        echo "ArgoCD will reconcile these once it's running"
      fi
      
      echo "✅ ArgoCD bootstrap initiated - it will manage all applications including Cilium"
    EOT
  }

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}

# Get ArgoCD admin password after deployment
resource "null_resource" "argocd_info" {
  count = var.configure_talos ? 1 : 0

  depends_on = [null_resource.argocd_install, null_resource.argocd_bootstrap]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail

      export KUBECONFIG=${abspath("${path.module}/../kubeconfig")}

      echo ""
      echo "📝 ArgoCD initial admin password:"
      kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d || echo "Secret not found"
      echo ""
      echo ""
      echo "🌐 Access ArgoCD:"
      echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
      echo "  Then visit: https://localhost:8080"
      echo "  Username: admin"
    EOT
  }
}
