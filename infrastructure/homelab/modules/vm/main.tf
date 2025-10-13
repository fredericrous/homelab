resource "proxmox_virtual_environment_vm" "vm" {
  vm_id       = var.vmid
  name        = var.name
  node_name   = var.target_node
  description = "Managed by Terraform"
  tags        = ["terraform", "talos"]

  # QEnable QEMU guest agent
  agent {
    enabled = true
  }

  # Hardware configuration
  cpu {
    cores = var.cores
    type  = "host"
    # Additional CPU flags for better GPU passthrough compatibility
    flags = var.gpu_passthrough != "" && var.gpu_passthrough != null ? ["+pcid"] : []
  }

  memory {
    dedicated = var.memory
  }

  # BIOS and boot settings
  bios = "ovmf"

  # Use pc-q35-8.1 for better GPU passthrough compatibility
  machine = var.gpu_passthrough != "" && var.gpu_passthrough != null ? "pc-q35-8.1" : "q35"

  # EFI disk for UEFI boot
  efi_disk {
    datastore_id = var.disk_storage
    file_format  = "raw"
    type         = "4m"
  }

  # Network
  network_device {
    model       = "virtio"
    bridge      = var.bridge
    mac_address = var.mac_address != "" && var.mac_address != null ? var.mac_address : null
  }

  # GPU Passthrough (if specified)
  dynamic "hostpci" {
    for_each = var.gpu_passthrough != "" && var.gpu_passthrough != null ? [1] : []
    content {
      device = "hostpci0"
      id     = var.gpu_passthrough
      pcie   = true
      rombar = true # Enable ROM BAR for GPU
      xvga   = true # Enable VGA passthrough for primary GPU
    }
  }

  # VGA configuration - we do not disable even when using GPU passthrough,
  # as we want talos console and disabling doesn't help with kubernetes nvidia device plugin
  vga {
    type = "std"
  }

  # Boot/OS disk
  disk {
    datastore_id = var.disk_storage
    size         = var.os_disk_size
    interface    = "scsi0"
    cache        = "writethrough"
    ssd          = true
    discard      = "on"
    iothread     = true
  }

  # Additional data disk (if specified)
  dynamic "disk" {
    for_each = length(var.additional_disks) > 0 ? var.additional_disks : []
    content {
      datastore_id = var.disk_storage
      size         = disk.value.size
      interface    = "scsi${disk.key + 1}"
      cache        = "writethrough"
      ssd          = true
      discard      = "on"
      iothread     = true
    }
  }

  # ISO for boot
  cdrom {
    file_id = var.iso_file
  }

  # Boot order - boot from CD first for initial install
  boot_order = ["ide2", "scsi0"]

  scsi_hardware = "virtio-scsi-single"

  started = true
  on_boot = true

  operating_system {
    type = "l26"
  }

  # Cloud-init configuration for network only
  # Talos doesn't use cloud-init users, but Proxmox requires a username
  initialization {
    interface    = "ide2" # Use ide0 for cloud-init, ide2 is for cdrom (normally but we use ide2 here to avoid conflicts)
    datastore_id = var.disk_storage

    # Minimal user config to satisfy Proxmox requirement
    # Talos ignores this, uses its own user management
    user_account {
      username = "talos"
      keys     = []
    }

    # Network configuration (only if IP is provided)
    dynamic "ip_config" {
      for_each = var.ip_address != "" ? [1] : []
      content {
        ipv4 {
          address = "${var.ip_address}/24"
          gateway = var.gateway != "" ? var.gateway : "192.168.1.1"
        }
      }
    }

    # DNS servers
    dns {
      servers = length(var.dns_servers) > 0 ? var.dns_servers : ["1.1.1.1", "8.8.8.8"]
    }
  }


  # Timeout configurations for various operations
  timeout_create      = 600 # 10 minutes for creation
  timeout_stop_vm     = 60  # 1 minute for stopping (reduced for faster destroy)
  timeout_shutdown_vm = 60  # 1 minute for shutdown (Talos doesn't respond to ACPI)
  timeout_reboot      = 300 # 5 minutes for reboot

  # Force stop on destroy since Talos doesn't respond to graceful shutdown
  stop_on_destroy = true

  lifecycle {
    ignore_changes = [
      network_device,
      disk,
      cdrom,
    ]
    create_before_destroy = false
  }

}
