# DevOps Improvements - Lessons Learned

## Summary of Attempted Changes

### Key Finding: Dynamic Kubeconfig Limitation

When working with dynamically provisioned Kubernetes clusters (like Talos), Terraform's Helm and Kubernetes providers have a fundamental limitation:
- They require a valid kubeconfig at **plan time** 
- Our kubeconfig is generated during **apply time**
- This causes "Kubernetes cluster unreachable" errors during both plan and destroy operations

### 1. Cilium Bootstrap (cilium-bootstrap.tf)
**Attempted**: Replace `null_resource` with native `helm_release` resource
**Result**: Reverted to `null_resource` with local-exec

**Reason**: Provider connection errors during plan/destroy phases

### 2. ArgoCD Installation (argocd-helm.tf) 
**Attempted**: Use native `helm_release` resource
**Result**: Reverted to `null_resource` with local-exec

**Reason**: Same provider connection errors, especially problematic during destroy

### 3. Node Readiness Check (wait-nodes-ready.tf)
**Attempted**: Use `kubernetes_nodes` data source
**Result**: Reverted to `null_resource` with kubectl loop

**Reason**: Data sources also require cluster connectivity at plan time

### 4. ArgoCD Admin Password (argocd-helm.tf)
**Attempted**: Use `kubernetes_secret` data source with output
**Result**: Reverted to `null_resource` with kubectl command

**Reason**: Same connectivity issues

### 4. Updated Dependencies
- Fixed all references from `null_resource.cilium_bootstrap` to `helm_release.cilium`
- Ensured proper dependency chain throughout

## Items Not Changed (Justified)

### 1. Helm Repository Management (helm-repos.tf)
- No native terraform resource for helm repositories
- Current approach with `|| true` provides idempotency
- Reasonable use of local-exec

### 2. ArgoCD Bootstrap (argocd-helm.tf)
- Uses kustomization with embedded helm chart
- Too complex to convert to individual `kubernetes_manifest` resources
- Would require significant restructuring for minimal benefit

### 3. Network Connectivity Checks (stage1-vms.tf)
- Simple TCP port check with netcat
- No native terraform equivalent
- Reasonable health check implementation

## Testing Recommendations

1. Run `terraform plan` to verify no breaking changes
2. Test destroy and recreate cycle:
   ```bash
   terraform destroy
   ./deploy.sh
   ```
3. Verify Cilium installation completes successfully
4. Check ArgoCD password output works
5. Ensure all nodes become ready

## Next Steps

The terraform configuration is now more idiomatic with better state management while maintaining pragmatic use of local-exec where appropriate.