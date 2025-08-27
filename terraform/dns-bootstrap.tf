# Bootstrap DNS service to ensure DNS works before ArgoCD takes over
# This creates the kube-dns service with the correct selector for Talos-deployed CoreDNS
resource "null_resource" "dns_bootstrap" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [
    talos_machine_bootstrap.this,
    talos_cluster_kubeconfig.this,
    local_file.kubeconfig
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
      
      echo "🔍 Checking if kube-dns service exists..."
      if kubectl get svc -n kube-system kube-dns >/dev/null 2>&1; then
        echo "✅ kube-dns service already exists"
        # Check if it has the correct selector
        SELECTOR=$(kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.selector}' | jq -r 'to_entries | map(select(.key == "k8s-app" and .value == "kube-dns")) | length')
        if [ "$SELECTOR" -eq 1 ]; then
          OTHER_SELECTORS=$(kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.selector}' | jq -r 'to_entries | length')
          if [ "$OTHER_SELECTORS" -eq 1 ]; then
            echo "✅ kube-dns service has correct selector"
            exit 0
          fi
        fi
        echo "⚠️  kube-dns service exists but has incorrect selector, recreating..."
        kubectl delete svc -n kube-system kube-dns
      fi
      
      echo "🚀 Creating bootstrap kube-dns service..."
      cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
    kubernetes.io/name: "CoreDNS"
  annotations:
    # This service is managed by ArgoCD after bootstrap
    argocd.argoproj.io/sync-options: ServerSideApply=true
spec:
  selector:
    k8s-app: kube-dns
  clusterIP: 10.96.0.10
  ports:
  - name: dns
    port: 53
    protocol: UDP
    targetPort: 53
  - name: dns-tcp
    port: 53
    protocol: TCP
    targetPort: 53
  - name: metrics
    port: 9153
    protocol: TCP
    targetPort: 9153
EOF
      
      echo "⏳ Waiting for DNS endpoints to be ready..."
      for i in {1..30}; do
        ENDPOINTS=$(kubectl get endpoints -n kube-system kube-dns -o jsonpath='{.subsets[0].addresses}' 2>/dev/null || echo "")
        if [ -n "$ENDPOINTS" ]; then
          echo "✅ DNS endpoints are ready"
          
          # Test DNS resolution is actually working
          echo "🧪 Testing DNS resolution..."
          if kubectl run dns-test-$RANDOM --image=busybox:1.28 --restart=Never --rm -i --timeout=10s --command -- nslookup kubernetes.default.svc.cluster.local 2>&1 | grep -q "Address.*10.96.0.1"; then
            echo "✅ DNS resolution is working"
            break
          else
            echo "⚠️  DNS endpoints exist but resolution not working yet... ($i/30)"
          fi
        else
          echo "Waiting for DNS endpoints... ($i/30)"
        fi
        sleep 2
      done
      
      echo "✅ Bootstrap DNS service created successfully"
    EOT
  }

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}