# Terraform Deployment for Talos on Proxmox

This Terraform configuration deploys a complete Talos Linux Kubernetes cluster on Proxmox with:
- 1 Control Plane node (2 cores, 12GB RAM)
- 1 Worker node with GPU passthrough (12 cores, 48GB RAM)
- 1 Worker node (10 cores, 37GB RAM)

The configuration uses the official Talos Terraform provider to handle the complete lifecycle: VM creation, Talos installation, configuration, and cluster bootstrap.

## Network Configuration

This setup uses predefined IP addresses for each VM to ensure consistent network configuration:
- Control Plane: `192.168.1.67`
- Worker 1 (GPU): `192.168.1.68`
- Worker 2: `192.168.1.69`

## Prerequisites

1. **QNAP Services Deployed** (Required for Vault transit unseal):
   ```bash
   cd ../nas/
   ./deploy-k3s-services.sh
   # Initialize Vault and save the root token (shown after initialization)
   # The transit token is created automatically
   ```

2. Proxmox VE installed and configured
3. GPU passthrough configured in Proxmox (for worker-1-gpu)
4. Talos ISO uploaded to Proxmox ISO storage
5. Terraform and required CLI tools installed locally

## Usage

### 1. Configure Terraform

```bash
# Copy and edit the variables file
cp terraform.tfvars.example terraform.tfvars

# Edit terraform.tfvars with:
# - Proxmox credentials and settings
# - Network configuration (IPs, gateway, DNS)
```

### 2. Deploy the Cluster

Due to Talos requiring nodes to be accessible at their static IPs, deployment is a two-stage process:

#### Automated Deployment (Recommended)

```bash
# Install Taskfile (one-time)
brew install go-task  # macOS
# or see https://taskfile.dev/installation/

# Export QNAP Vault root token
export QNAP_VAULT_TOKEN=<qnap-vault-root-token>
# The transit token will be automatically retrieved

# Run the deployment
cd ..
task deploy

# Or resume from a specific stage (e.g., after a failure)
task stage7  # Continues from stage 7
```

Benefits:
- **Resumable**: Start from any stage with `task stage7`
- **Idempotent**: Won't re-run completed stages
- **Clear status**: `task --list` shows all available tasks
- **Fail fast** with helpful error messages


This will:
1. Create VMs with predefined MAC addresses
2. Wait for VMs to boot and get DHCP IPs
3. Automatically retrieve IPs from Proxmox API using QEMU guest agent
4. Apply Talos configuration to the DHCP IPs
5. Wait for nodes to reboot with static IPs
6. Complete cluster bootstrap and generate kubeconfig
7. Setup Vault transit auto-unseal
8. Deploy core services via ArgoCD

Taskfile handles everything automatically with resumability - if any stage fails, just run it again!

#### Manual Two-Stage Deployment

**Stage 1: Create VMs**
```bash
terraform init
terraform apply -target=module.vms
```

**Configure Network** (choose one):
- Option A: Configure DHCP reservations on your router for the MAC addresses
- Option B: Manually apply Talos config to DHCP IPs (see instructions below)

**Stage 2: Configure Talos**
```bash
terraform apply -var="configure_talos=true"
```

### 3. Access the Cluster

```bash
# Use the generated kubeconfig
export KUBECONFIG=./kubeconfig
kubectl get nodes

# Use talosctl with the generated config
talosctl --talosconfig ./talosconfig get members
```

### 4. Install Cilium CNI

Since we disabled flannel, install Cilium:

```bash
kubectl apply -k ../manifests/cilium/
```

## Project Structure

```
terraform/
├── main.tf              # Provider config and VM creation using for_each
├── talos.tf             # All Talos resources (consolidated)
├── locals.tf            # Local values for DRY principle
├── versions.tf          # Terraform and provider requirements
├── variables.tf         # Input variables with validation
├── outputs.tf           # Dynamic outputs
├── terraform.tfvars     # Your environment values (gitignored)
├── terraform.tfvars.example # Example values
└── modules/
    └── vm/              # Reusable VM module
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

### Key Features

- **DRY Principle**: Node configurations defined once in `locals.tf`
- **For Each Loops**: VMs and Talos configs created dynamically
- **Input Validation**: Variables validated for correct format
- **Dynamic Outputs**: Outputs generated from node configuration
- **Easy Extension**: Add new nodes by updating `locals.tf`

## Configuration

### VM Specifications

**Control Plane (VM 100)**:
- CPU: 2 cores
- RAM: 12GB
- Disk: 32GB

**Worker 1 GPU (VM 101)**:
- CPU: 12 cores
- RAM: 48GB
- Disk: 128GB (OS) + 800GB (data)
- GPU: PCIe passthrough (0000:01:00)

**Worker 2 (VM 102)**:
- CPU: 10 cores
- RAM: 37GB
- Disk: 96GB (OS) + 640GB (data)

### Network Configuration

All VMs use:
- Bridge: vmbr0
- Network model: virtio
- Static IPs configured via Cloud Init

### Patches Applied

1. **disable-proxy-flannel.yaml**: Disables kube-proxy and default CNI (flannel) for Cilium
2. **common-extensions.yaml**: Installs QEMU guest agent and AMD microcode on all nodes
3. **gpu-worker-patch.yaml**: Configures GPU support and NVIDIA extensions on worker-1
4. **sysctls-patch.yaml**: System tuning parameters
6. **controlplane-ips-patch.yaml**: Control plane specific configuration
7. **worker-ips-patch.yaml**: Worker nodes specific configuration

## Troubleshooting

### VMs don't start
- Check Proxmox logs
- Ensure ISO is properly uploaded
- Verify storage has enough space

### GPU passthrough issues
- Verify IOMMU is enabled in BIOS
- Check Proxmox GPU passthrough configuration
- Ensure GPU IDs in terraform match your hardware

### Network issues
- Verify bridge configuration in Proxmox
- Check DHCP reservations match MAC addresses
- Ensure firewall rules allow required ports

## Cleanup

To destroy all VMs:

```bash
terraform destroy
```

## Notes

- The VMs are configured with UEFI boot (OVMF BIOS)
- All disks use virtio-scsi with cache=writethrough
- The configuration assumes local-lvm storage in Proxmox
- Adjust storage, network, and other settings in variables.tf as needed
