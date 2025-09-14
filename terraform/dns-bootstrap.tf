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
        # Check if CoreDNS pods exist and are running
        COREDNS_PODS=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | wc -l | tr -d ' ')
        COREDNS_READY=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
        
        # Check endpoints
        ENDPOINTS=$(kubectl get endpoints -n kube-system kube-dns -o jsonpath='{.subsets[0].addresses}' 2>/dev/null || echo "")
        ENDPOINT_COUNT=$(kubectl get endpoints -n kube-system kube-dns -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null | wc -w | tr -d ' ')
        
        echo "Status: CoreDNS pods: $COREDNS_READY/$COREDNS_PODS ready, Endpoints: $ENDPOINT_COUNT"
        
        # If no CoreDNS pods at all, provide specific guidance
        if [ "$COREDNS_PODS" -eq 0 ]; then
          echo "  ⚠️  No CoreDNS pods found. Talos should deploy CoreDNS automatically."
          echo "  Checking node status..."
          kubectl get nodes --no-headers | awk '{print "    " $1 ": " $2}'
        elif [ "$COREDNS_READY" -lt "$COREDNS_PODS" ]; then
          echo "  ⏳ CoreDNS pods are starting up..."
          kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers | awk '{print "    " $1 ": " $2 " " $3}'
        elif [ -n "$ENDPOINTS" ] && [ "$ENDPOINT_COUNT" -gt 0 ]; then
          echo "  ✅ DNS endpoints are ready ($ENDPOINT_COUNT endpoints)"
          
          # Test DNS resolution is actually working
          echo "  🧪 Testing DNS resolution..."
          TEST_OUTPUT=$(kubectl run dns-test-$RANDOM --image=busybox:1.28 --restart=Never --rm -i --timeout=10s --command -- nslookup kubernetes.default.svc.cluster.local 2>&1 || echo "DNS test failed")
          
          if echo "$TEST_OUTPUT" | grep -q "Address.*10.96.0.1"; then
            echo "  ✅ DNS resolution is working!"
            break
          else
            echo "  ⚠️  DNS endpoints exist but resolution not working yet"
            echo "  Test output: $(echo "$TEST_OUTPUT" | grep -E "(can't resolve|Address:|error)" | head -1)"
          fi
        else
          echo "  ⏳ Waiting for endpoints to be created..."
        fi
        
        # Don't wait forever - after 20 attempts, show more debugging
        if [ $i -eq 20 ]; then
          echo ""
          echo "  🔍 Extended diagnostics:"
          echo "  CoreDNS deployment:"
          kubectl get deployment -n kube-system coredns --no-headers 2>/dev/null || echo "    No coredns deployment found"
          echo "  DNS service:"
          kubectl get svc -n kube-system kube-dns -o wide --no-headers 2>/dev/null || echo "    No kube-dns service found"
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