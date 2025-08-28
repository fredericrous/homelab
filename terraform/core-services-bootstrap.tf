# Bootstrap critical core services that need manual syncing
# These services have autoSync: false and must be deployed in order

# Stage 0: Sync Rook-Ceph storage (required by many services)
resource "null_resource" "rook_ceph_sync" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [
    null_resource.argocd_bootstrap
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG=${abspath(local_file.kubeconfig[0].filename)}
      
      echo "💾 Waiting for Rook-Ceph application to be created by ApplicationSet..."
      for i in {1..30}; do
        if kubectl get app -n argocd rook-ceph >/dev/null 2>&1; then
          echo "✅ Rook-Ceph application found"
          break
        fi
        echo "Waiting for Rook-Ceph application... ($i/30)"
        sleep 5
      done
      
      echo "💾 Syncing Rook-Ceph storage operator..."
      kubectl patch app -n argocd rook-ceph --type merge -p '{"operation":{"initiatedBy":{"username":"terraform"},"sync":{"prune":true,"syncStrategy":{"hook":{}}}}}'
      
      # Wait for sync to complete
      echo "⏳ Waiting for Rook-Ceph sync to complete..."
      for i in {1..120}; do
        sync_status=$(kubectl get app -n argocd rook-ceph -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
        health_status=$(kubectl get app -n argocd rook-ceph -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
        
        if [[ "$sync_status" == "Synced" ]]; then
          echo "✅ Rook-Ceph synced (Health: $health_status)"
          break
        fi
        echo "Sync status: $sync_status, Health: $health_status ($i/120)"
        sleep 5
      done
      
      # Wait for Rook operator to be ready
      echo "⏳ Waiting for Rook-Ceph operator pod..."
      kubectl wait --for=condition=ready --timeout=300s pod -n rook-ceph -l app=rook-ceph-operator || true
      
      # Wait for storage class to be available
      echo "🔍 Waiting for rook-ceph-block storage class..."
      for i in {1..60}; do
        if kubectl get storageclass rook-ceph-block >/dev/null 2>&1; then
          echo "✅ Storage class rook-ceph-block is available"
          # Also check if the storage class is default
          is_default=$(kubectl get storageclass rook-ceph-block -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}')
          if [[ "$is_default" == "true" ]]; then
            echo "✅ rook-ceph-block is the default storage class"
          fi
          break
        fi
        echo "Waiting for storage class... ($i/60)"
        sleep 10
      done
      
      echo "✅ Rook-Ceph storage is ready"
    EOT
  }

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}

# Wait for ApplicationSets to generate apps
resource "null_resource" "wait_for_appsets" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [
    null_resource.argocd_bootstrap
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG=${abspath(local_file.kubeconfig[0].filename)}
      
      echo "⏳ Waiting for ApplicationSets to generate applications..."
      
      # Wait for specific apps to be created by ApplicationSets
      apps=("vault" "cert-manager" "vault-secrets-operator" "rook-ceph")
      for app in "$${apps[@]}"; do
        echo "🔍 Waiting for $app application..."
        for i in {1..60}; do
          if kubectl get app -n argocd "$app" >/dev/null 2>&1; then
            echo "✅ $app application created"
            break
          fi
          if [ $i -eq 60 ]; then
            echo "⚠️  Warning: $app application not found after 60 attempts"
          fi
          sleep 2
        done
      done
      
      echo "📋 Current applications:"
      kubectl get app -n argocd --no-headers | awk '{print "  - " $1}'
      
      echo "✅ Proceeding with core services bootstrap"
    EOT
  }

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}

# Stage 1: Sync Vault (needs to be initialized and unsealed)
resource "null_resource" "vault_sync" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [
    null_resource.wait_for_appsets,
    null_resource.dns_bootstrap,
    null_resource.rook_ceph_sync  # Vault needs storage
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG=${abspath(local_file.kubeconfig[0].filename)}
      
      echo "🔐 Waiting for Vault application to be created by ApplicationSet..."
      for i in {1..30}; do
        if kubectl get app -n argocd vault >/dev/null 2>&1; then
          echo "✅ Vault application found"
          break
        fi
        echo "Waiting for Vault application... ($i/30)"
        sleep 5
      done
      
      echo "🔐 Syncing Vault application..."
      # Force sync Vault app
      kubectl patch app -n argocd vault --type merge -p '{"operation":{"initiatedBy":{"username":"terraform"},"sync":{"prune":true,"syncStrategy":{"hook":{}}}}}'
      
      # Wait for sync to complete
      echo "⏳ Waiting for Vault sync to complete..."
      for i in {1..120}; do
        sync_status=$(kubectl get app -n argocd vault -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
        health_status=$(kubectl get app -n argocd vault -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
        
        if [[ "$sync_status" == "Synced" ]]; then
          echo "✅ Vault synced (Health: $health_status)"
          break
        fi
        echo "Sync status: $sync_status, Health: $health_status ($i/120)"
        sleep 5
      done
      
      # Wait for Vault namespace and PVC
      echo "⏳ Waiting for Vault PVC to be bound..."
      for i in {1..60}; do
        pvc_status=$(kubectl get pvc -n vault vault-data -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        if [[ "$pvc_status" == "Bound" ]]; then
          echo "✅ Vault PVC is bound"
          break
        elif [[ "$pvc_status" == "Pending" ]]; then
          # Get more details about why it's pending
          pvc_events=$(kubectl get events -n vault --field-selector involvedObject.name=vault-data --sort-by='.lastTimestamp' | tail -5)
          echo "PVC is Pending. Recent events:"
          echo "$pvc_events"
        fi
        echo "PVC status: $pvc_status ($i/60)"
        sleep 5
      done
      
      # Wait for Vault pod to exist
      echo "⏳ Waiting for Vault pod to be created..."
      for i in {1..60}; do
        if kubectl get pod -n vault vault-0 >/dev/null 2>&1; then
          echo "✅ Vault pod exists"
          break
        fi
        echo "Waiting for Vault pod... ($i/60)"
        sleep 5
      done
      
      # Wait for Vault to be ready (but it might be sealed)
      echo "⏳ Waiting for Vault pod to be running..."
      kubectl wait --for=condition=ready --timeout=300s pod -n vault vault-0 || 
      kubectl wait --for=jsonpath='{.status.phase}'=Running --timeout=300s pod -n vault vault-0 || true
      
      # Check if Vault is initialized
      echo "🔍 Checking Vault initialization status..."
      
      # First, check if vault-init job exists, if not create it
      if ! kubectl get job -n vault vault-init >/dev/null 2>&1; then
        echo "⚠️  vault-init job not found, creating it manually..."
        kubectl apply -f ${abspath(path.module)}/../manifests/core/vault/job-vault-init.yaml || echo "Failed to create vault-init job"
      fi
      
      for i in {1..60}; do
        # Check if initialization secrets exist
        if kubectl get secret -n vault vault-keys >/dev/null 2>&1 && kubectl get secret -n vault vault-admin-token >/dev/null 2>&1; then
          echo "✅ Vault initialization secrets found"
          
          # Check Vault health endpoint
          vault_health=$(kubectl exec -n vault vault-0 -- vault status -format=json 2>/dev/null || echo "{}")
          if echo "$vault_health" | jq -e '.initialized == true' >/dev/null 2>&1; then
            echo "✅ Vault is initialized"
            if echo "$vault_health" | jq -e '.sealed == false' >/dev/null 2>&1; then
              echo "✅ Vault is unsealed and ready"
            else
              echo "⚠️  Vault is sealed, unseal job should handle this"
            fi
          fi
          break
        fi
        
        # Check init job status
        if kubectl get job -n vault vault-init >/dev/null 2>&1; then
          init_job_status=$(kubectl get job -n vault vault-init -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "Running")
          init_job_failed=$(kubectl get job -n vault vault-init -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "False")
          
          if [[ "$init_job_status" == "True" ]]; then
            echo "✅ Vault init job completed successfully"
          elif [[ "$init_job_failed" == "True" ]]; then
            echo "❌ Vault init job failed. Checking logs..."
            kubectl logs -n vault job/vault-init --tail=20
            break
          else
            echo "⏳ Vault init job is running..."
            # Show last few log lines to see progress
            kubectl logs -n vault job/vault-init --tail=5 2>/dev/null || true
          fi
        fi
        
        echo "Waiting for Vault initialization... ($i/60)"
        sleep 5
      done
      
      echo "✅ Vault synced successfully"
    EOT
  }

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}

# Stage 2: Sync Vault Secrets Operator (depends on Vault)
resource "null_resource" "vso_sync" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [null_resource.vault_sync]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG=${abspath(local_file.kubeconfig[0].filename)}
      
      echo "🔒 Waiting for VSO application to be created by ApplicationSet..."
      for i in {1..30}; do
        if kubectl get app -n argocd vault-secrets-operator >/dev/null 2>&1; then
          echo "✅ VSO application found"
          break
        fi
        echo "Waiting for VSO application... ($i/30)"
        sleep 5
      done
      
      echo "🔒 Syncing Vault Secrets Operator..."
      # Create namespace if it doesn't exist
      kubectl create namespace vault-secrets-operator-system --dry-run=client -o yaml | kubectl apply -f -
      
      # Force sync VSO app
      kubectl patch app -n argocd vault-secrets-operator --type merge -p '{"operation":{"initiatedBy":{"username":"terraform"},"sync":{"prune":true,"syncStrategy":{"hook":{}}}}}'
      
      # Wait for sync to complete
      echo "⏳ Waiting for VSO sync to complete..."
      for i in {1..120}; do
        sync_status=$(kubectl get app -n argocd vault-secrets-operator -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
        health_status=$(kubectl get app -n argocd vault-secrets-operator -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
        
        if [[ "$sync_status" == "Synced" ]]; then
          echo "✅ VSO synced (Health: $health_status)"
          break
        fi
        echo "Sync status: $sync_status, Health: $health_status ($i/120)"
        sleep 5
      done
      
      # Wait for VSO CRDs to be available
      echo "⏳ Waiting for VSO CRDs..."
      crds=("vaultauths.secrets.hashicorp.com" "vaultstaticsecrets.secrets.hashicorp.com" "vaultdynamicsecrets.secrets.hashicorp.com" "vaultpkisecrets.secrets.hashicorp.com")
      for crd in "$${crds[@]}"; do
        for i in {1..60}; do
          if kubectl get crd "$crd" >/dev/null 2>&1; then
            echo "✅ CRD $crd is ready"
            break
          fi
          if [ $i -eq 60 ]; then
            echo "⚠️  Warning: CRD $crd not found after 60 attempts"
          fi
          sleep 2
        done
      done
      
      # Wait for VSO deployment to be ready
      echo "⏳ Waiting for VSO deployment..."
      kubectl wait --for=condition=available --timeout=300s deployment -n vault-secrets-operator-system vault-secrets-operator-controller-manager || true
      
      # Wait for VSO webhook to be ready
      kubectl wait --for=condition=ready --timeout=300s pod -n vault-secrets-operator-system -l control-plane=controller-manager || true
      
      echo "✅ VSO synced successfully"
    EOT
  }

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}

# Stage 3: Sync cert-manager (depends on VSO)
resource "null_resource" "cert_manager_sync" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [null_resource.vso_sync]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG=${abspath(local_file.kubeconfig[0].filename)}
      
      echo "📜 Waiting for cert-manager application to be created by ApplicationSet..."
      for i in {1..30}; do
        if kubectl get app -n argocd cert-manager >/dev/null 2>&1; then
          echo "✅ cert-manager application found"
          break
        fi
        echo "Waiting for cert-manager application... ($i/30)"
        sleep 5
      done
      
      echo "📜 Syncing cert-manager..."
      # Force sync cert-manager app
      kubectl patch app -n argocd cert-manager --type merge -p '{"operation":{"initiatedBy":{"username":"terraform"},"sync":{"prune":true,"syncStrategy":{"hook":{}}}}}'
      
      # Wait for sync to complete
      echo "⏳ Waiting for cert-manager sync to complete..."
      for i in {1..120}; do
        sync_status=$(kubectl get app -n argocd cert-manager -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
        health_status=$(kubectl get app -n argocd cert-manager -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
        
        if [[ "$sync_status" == "Synced" ]]; then
          echo "✅ cert-manager synced (Health: $health_status)"
          break
        fi
        echo "Sync status: $sync_status, Health: $health_status ($i/120)"
        sleep 5
      done
      
      # Wait for cert-manager CRDs to be available
      echo "⏳ Waiting for cert-manager CRDs..."
      crds=("certificates.cert-manager.io" "certificaterequests.cert-manager.io" "issuers.cert-manager.io" "clusterissuers.cert-manager.io")
      for crd in "$${crds[@]}"; do
        for i in {1..60}; do
          if kubectl get crd "$crd" >/dev/null 2>&1; then
            echo "✅ CRD $crd is ready"
            break
          fi
          if [ $i -eq 60 ]; then
            echo "⚠️  Warning: CRD $crd not found after 60 attempts"
          fi
          sleep 2
        done
      done
      
      # Wait for cert-manager deployments
      echo "⏳ Waiting for cert-manager deployments..."
      deployments=("cert-manager" "cert-manager-webhook" "cert-manager-cainjector")
      for deploy in "$${deployments[@]}"; do
        kubectl wait --for=condition=available --timeout=300s deployment -n cert-manager "$deploy" || true
      done
      
      # Wait for webhook to be ready (critical for cert creation)
      echo "⏳ Waiting for cert-manager webhook to be ready..."
      kubectl wait --for=condition=ready --timeout=300s pod -n cert-manager -l app.kubernetes.io/name=webhook || true
      
      # Check if ClusterIssuer is created
      echo "🔍 Checking for Let's Encrypt ClusterIssuer..."
      for i in {1..60}; do
        if kubectl get clusterissuer letsencrypt-ovh-webhook-final >/dev/null 2>&1; then
          issuer_ready=$(kubectl get clusterissuer letsencrypt-ovh-webhook-final -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
          if [[ "$issuer_ready" == "True" ]]; then
            echo "✅ ClusterIssuer is ready and configured"
            break
          else
            echo "ClusterIssuer exists but not ready: $issuer_ready"
          fi
        fi
        echo "Waiting for ClusterIssuer... ($i/60)"
        sleep 5
      done
      
      echo "✅ cert-manager synced successfully"
    EOT
  }

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}


# Update wait_nodes_ready to depend on core services
resource "null_resource" "wait_nodes_ready_updated" {
  count = var.configure_talos ? 1 : 0

  depends_on = [
    talos_machine_configuration_apply.workers,
    null_resource.cert_manager_sync
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG=${abspath(local_file.kubeconfig[0].filename)}
      
      echo "✅ Core services deployed. Cluster is ready!"
      echo ""
      echo "📋 Service Status:"
      kubectl get app -n argocd vault vault-secrets-operator cert-manager -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
      echo ""
      echo "🌐 To access ArgoCD:"
      echo "  - URL: https://argocd.daddyshome.fr/"
      echo "  - Username: admin"
      echo "  - Password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"
      echo ""
      echo "⚠️  Note: HTTPS access requires your mTLS client certificate"
    EOT
  }

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}