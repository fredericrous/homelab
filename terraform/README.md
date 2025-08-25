# Terraform Deployment for Talos on Proxmox

This Terraform configuration deploys a complete Talos Linux Kubernetes cluster on Proxmox with:
- 1 Control Plane node (2 cores, 12GB RAM)
- 1 Worker node with GPU passthrough (12 cores, 48GB RAM)
- 1 Worker node (10 cores, 37GB RAM)

The configuration uses the official Talos Terraform provider to handle the complete lifecycle: VM creation, Talos installation, configuration, and cluster bootstrap.

## Network Configuration

This setup uses predefined MAC addresses for each VM to ensure consistent network configuration:
- Control Plane: `BC:24:11:00:00:67` → `192.168.1.67`
- Worker 1 (GPU): `BC:24:11:00:00:68` → `192.168.1.68`
- Worker 2: `BC:24:11:00:00:69` → `192.168.1.69`

You have two options for IP assignment:

### Option 1: DHCP Reservations (Recommended)
Configure your DHCP server/router to assign the static IPs based on the MAC addresses above. This ensures VMs get the correct IPs immediately on boot.

### Option 2: Talos Static Configuration
If you can't configure DHCP reservations, Talos will configure the static IPs after installation. The VMs will initially get random DHCP IPs, then reconfigure themselves with the static IPs defined in the Talos configuration.

## Prerequisites

1. Proxmox VE installed and configured
2. GPU passthrough configured in Proxmox (for worker-1-gpu)
3. Talos ISO uploaded to Proxmox ISO storage
4. Terraform installed locally

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
# Run the deployment script
./deploy.sh
```

This script will:
1. Create VMs with predefined MAC addresses
2. Wait for VMs to boot and get DHCP IPs
3. Automatically retrieve IPs from Proxmox API using QEMU guest agent
4. Apply Talos configuration to the DHCP IPs
5. Wait for nodes to reboot with static IPs
6. Complete cluster bootstrap and generate kubeconfig

The script handles everything automatically - no manual intervention required!

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

### Manual Talos Configuration (if not using DHCP reservations)

If you can't configure DHCP reservations, after Stage 1:

1. Find the DHCP IPs assigned to your VMs:
   - Check Proxmox console (Talos maintenance mode shows IP)
   - Check your router's DHCP lease table
   - Use `qm guest cmd <vmid> network-get-interfaces` on Proxmox

2. Apply configuration to each node:
   ```bash
   talosctl apply-config --insecure --nodes <DHCP_IP> --file configs/talos-cp-1.yaml
   talosctl apply-config --insecure --nodes <DHCP_IP> --file configs/talos-wk-1-gpu.yaml
   talosctl apply-config --insecure --nodes <DHCP_IP> --file configs/talos-wk-2.yaml
   ```

3. Wait for nodes to reboot with static IPs, then continue with Stage 2

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
- Static IPs configured via DHCP reservation or Talos configuration

### Patches Applied

1. **disable-proxy-flannel.yaml**: Disables kube-proxy and default CNI (flannel) for Cilium
2. **common-extensions.yaml**: Installs QEMU guest agent and AMD microcode on all nodes
3. **gpu-worker-patch.yaml**: Configures GPU support and NVIDIA extensions on worker-1
4. **sysctls-patch.yaml**: System tuning parameters
5. **harbor-insecure-registry.yaml**: Harbor registry configuration
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