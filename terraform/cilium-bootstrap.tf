# Bootstrap Cilium CNI before ArgoCD
# This is needed because ArgoCD itself needs CNI to run

# Note: We use null_resource with local-exec instead of helm_release because
# the kubeconfig doesn't exist at terraform plan time, which causes provider errors
resource "null_resource" "cilium_bootstrap" {
  count = var.configure_talos ? 1 : 0

  depends_on = [
    talos_cluster_kubeconfig.this,
    talos_machine_bootstrap.this,
    local_file.kubeconfig,
    null_resource.helm_repos
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG=${abspath(local_file.kubeconfig[0].filename)}
      export TALOSCONFIG=${abspath(local_file.talosconfig.filename)}
      
      echo "🔍 Checking if Cilium is already installed..."
      if kubectl get deployment -n kube-system cilium-operator >/dev/null 2>&1; then
        echo "✅ Cilium already installed, skipping bootstrap"
        exit 0
      fi
      
      echo "⏳ Waiting for Kubernetes API to be accessible..."
      for i in {1..60}; do
        if kubectl cluster-info >/dev/null 2>&1; then
          echo "✅ API server is ready!"
          kubectl cluster-info
          break
        else
          echo "Waiting for API server... ($i/60)"
          # Also check with curl to see if port is open
          nc -zv 192.168.1.67 6443 2>&1 || true
          sleep 5
        fi
        
        if [ $i -eq 60 ]; then
          echo "❌ Timeout waiting for API server"
          echo "Debug: Checking talosctl service status..."
          talosctl -n 192.168.1.67 service | grep -E "(etcd|kube-apiserver)" || true
          exit 1
        fi
      done
      
      echo "🚀 Installing minimal Cilium for bootstrap..."
      echo "Note: Talos nodes will show 'node not found' errors until CNI is ready - this is normal!"
      
      # Check current node status before installing
      echo "Current node status:"
      kubectl get nodes || echo "Nodes may not be visible yet"
      
      # Key for Talos: use localhost:7445 for API server access (KubePrism)
      # Add tolerations to ensure Cilium can be scheduled during bootstrap
      helm install cilium cilium/cilium \
        --version 1.18.0 \
        --namespace kube-system \
        --set ipam.mode=kubernetes \
        --set kubeProxyReplacement=true \
        --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
        --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
        --set cgroup.autoMount.enabled=false \
        --set cgroup.hostRoot=/sys/fs/cgroup \
        --set k8sServiceHost=localhost \
        --set k8sServicePort=7445 \
        --set tolerations[0].operator=Exists \
        --set tolerations[0].effect=NoSchedule \
        --set tolerations[1].operator=Exists \
        --set tolerations[1].effect=NoExecute \
        --set tolerations[2].operator=Exists \
        --set tolerations[2].effect=PreferNoSchedule \
        --set tolerations[3].key=node-role.kubernetes.io/control-plane \
        --set tolerations[3].operator=Exists \
        --set tolerations[3].effect=NoSchedule \
        --set tolerations[4].key=node.cloudprovider.kubernetes.io/uninitialized \
        --set tolerations[4].operator=Exists \
        --set tolerations[4].effect=NoSchedule \
        --set tolerations[5].key=node.kubernetes.io/not-ready \
        --set tolerations[5].operator=Exists \
        --set tolerations[5].effect=NoSchedule \
        --wait --timeout 5m
        
      echo "✅ Cilium installed, nodes should start becoming ready..."
      
      echo "⏳ Waiting for nodes to become Ready..."
      for i in {1..60}; do
        if kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' | grep -v True > /dev/null; then
          echo "Waiting for nodes... ($i/60)"
          sleep 5
        else
          echo "✅ All nodes are Ready!"
          break
        fi
      done
      
      # Note: ArgoCD will manage Cilium going forward via GitOps
    EOT
  }

  # Trigger replacement if cluster is recreated
  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}
