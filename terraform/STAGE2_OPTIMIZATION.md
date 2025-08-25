# Stage 2 Optimization Changes

## Performance Improvements Implemented

### 1. **Removed Double-Patching**
- Config patches are now only applied in `data.talos_machine_configuration.nodes`
- Removed duplicate `config_patches` from `talos_machine_configuration_apply` resources
- This prevents Terraform from thinking there's always something to change

### 2. **Two-Wave Deployment**
- **Wave 1**: Control plane configuration and bootstrap
  - `talos_machine_configuration_apply.cp` (control plane only)
  - `talos_machine_bootstrap.this`
- **Wave 2**: Worker configuration after bootstrap
  - `talos_machine_configuration_apply.workers` (workers only)
  - Uses control plane endpoint for better stability

### 3. **Directory Creation Optimization**
- Added `null_resource.ensure_configs_dir` to create configs directory once
- Machine configs now depend on this resource instead of each running `mkdir -p`

### 4. **Improved Dependencies**
- Workers wait for bootstrap to complete before configuration
- Kubeconfig retrieval waits for all workers to be configured
- Using control plane endpoint for worker configuration (more stable)

## Usage

### Option 1: Automated Script (Recommended)
```bash
./deploy-optimized.sh
```

### Option 2: Manual Two-Wave Deployment
```bash
# Wave 1: Control plane
terraform apply -parallelism=10 -var="configure_talos=true" \
  -target=talos_machine_configuration_apply.cp \
  -target=talos_machine_bootstrap.this

# Wave 2: Workers
terraform apply -parallelism=10 -var="configure_talos=true" \
  -target=talos_machine_configuration_apply.workers \
  -target=talos_cluster_kubeconfig.this
```

### Option 3: Fast Path (Commented Out)
There's an optional `null_resource.apply_configs_fast` that uses `talosctl` directly
for even faster deployment. Uncomment it in `stage2-talos.tf` if you prefer speed
over pure Terraform approach.

## Benefits
- Significantly faster deployment (minutes instead of timing out)
- More reliable bootstrap process
- Better error visibility
- Can still use standard `terraform apply` if needed