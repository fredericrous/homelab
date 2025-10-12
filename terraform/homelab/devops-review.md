# Terraform DevOps Review

## Summary
After reviewing the terraform folder, I've identified several opportunities to replace `local-exec` provisioners with native Terraform resources. This will improve idempotency, state management, and error handling.

## Current Local-Exec Usage

### 1. **helm-repos.tf** - Helm Repository Management
- **Current**: Uses `local-exec` to run `helm repo add` commands
- **Improvement**: The helm provider doesn't have a native resource for managing repositories. The current approach with `|| true` is actually reasonable for idempotency.
- **Recommendation**: Keep as-is, but consider using a data source to check if repos exist first.

### 2. **cilium-bootstrap.tf** - Cilium CNI Installation
- **Current**: Uses `local-exec` to install Cilium with helm CLI
- **Improvement**: Replace with `helm_release` resource
- **Benefits**: 
  - Terraform manages the release state
  - Built-in idempotency
  - Better error handling and rollback

### 3. **argocd-helm.tf** - ArgoCD Deployment
- **Current**: Already uses `helm_release` resource ✅
- **Local-exec usage**: 
  - Bootstrap with kubectl apply
  - Display admin password
- **Improvement**: Replace kubectl apply with `kubernetes_manifest` resources
- **Note**: The info display can remain as local-exec since it's just informational

### 4. **wait-nodes-ready.tf** - Node Readiness Check
- **Current**: Shell script loop checking node status
- **Improvement**: This is challenging to replace as Terraform doesn't have native "wait for condition" resources
- **Alternative**: Could use `kubernetes_nodes` data source with retry logic, but the current approach is more robust
- **Recommendation**: Keep as-is

### 5. **stage2-talos.tf** - Talos Configuration
- **Current**: Uses native Talos provider resources ✅
- **Local-exec**: Only in commented-out fast path
- **Recommendation**: Already following best practices

### 6. **stage1-vms.tf** - VM Creation
- **Current**: Uses `local-exec` for network connectivity check
- **Improvement**: Limited options as this is a TCP port check
- **Recommendation**: Keep as-is, this is a reasonable health check

## Recommended Changes

### 1. Replace Cilium Bootstrap (cilium-bootstrap.tf)
```hcl
resource "helm_release" "cilium" {
  count = var.configure_talos ? 1 : 0

  depends_on = [
    talos_cluster_kubeconfig.this,
    talos_machine_bootstrap.this
  ]

  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = "1.18.0"
  namespace  = "kube-system"

  wait          = true
  wait_for_jobs = true
  timeout       = 300

  set {
    name  = "ipam.mode"
    value = "kubernetes"
  }

  set {
    name  = "kubeProxyReplacement"
    value = "true"
  }

  set {
    name  = "securityContext.capabilities.ciliumAgent"
    value = "{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}"
  }

  set {
    name  = "securityContext.capabilities.cleanCiliumState"
    value = "{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}"
  }

  set {
    name  = "cgroup.autoMount.enabled"
    value = "false"
  }

  set {
    name  = "cgroup.hostRoot"
    value = "/sys/fs/cgroup"
  }

  set {
    name  = "k8sServiceHost"
    value = "localhost"
  }

  set {
    name  = "k8sServicePort"
    value = "7445"
  }
}

# Wait for nodes using data source instead of local-exec
data "kubernetes_nodes" "all" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [helm_release.cilium]
}

resource "time_sleep" "wait_for_nodes" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [helm_release.cilium]

  create_duration = "60s"
}
```

### 2. Replace ArgoCD Bootstrap (argocd-helm.tf)
Instead of `kubectl apply -f`, read the manifests and use `kubernetes_manifest`:

```hcl
# Read ArgoCD bootstrap manifests
data "kubectl_path_documents" "argocd_bootstrap" {
  count   = var.configure_talos ? 1 : 0
  pattern = "${path.module}/../manifests/argocd/*.yaml"
}

# Apply manifests using kubernetes provider
resource "kubernetes_manifest" "argocd_bootstrap" {
  for_each = var.configure_talos ? { 
    for doc in try(data.kubectl_path_documents.argocd_bootstrap[0].documents, []) : 
    sha256(doc) => doc 
  } : {}

  depends_on = [helm_release.argocd]

  manifest = yamldecode(each.value)
}
```

Note: This requires the `kubectl` provider for reading multiple YAML documents.

## Benefits of These Changes

1. **State Management**: Terraform tracks resource state properly
2. **Idempotency**: No need for manual checks like "if deployment exists"
3. **Error Handling**: Better error messages and rollback capabilities
4. **Plan/Apply**: Can preview changes with `terraform plan`
5. **Destroy**: Clean removal with `terraform destroy`

## Items to Keep as Local-Exec

1. **Helm repo management** - No native terraform resource available
2. **Node readiness checks** - Complex logic that's hard to express declaratively
3. **Network connectivity checks** - Simple TCP port checks
4. **Information display** - Admin passwords, access instructions

## Next Steps

1. Implement the Cilium helm_release replacement
2. Test the ArgoCD manifest application with kubernetes_manifest
3. Consider adding the kubectl provider for multi-document YAML support
4. Maintain the current local-exec for scenarios where it makes sense