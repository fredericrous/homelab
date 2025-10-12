locals {
  # Default configurations
  controlplane_defaults = {
    cores           = 2
    memory          = 12288
    os_disk_size    = 32
    data_disk_size  = 491
    gpu_passthrough = null
    labels          = {}
  }

  worker_defaults = {
    cores           = 4
    memory          = 8192
    os_disk_size    = 64
    data_disk_size  = 200
    gpu_passthrough = null
    labels          = {}
  }

  # Filter out null values from user input
  controlplane_user_values = {
    for k, v in var.nodes.controlplane : k => v
    if v != null
  }

  # Merge user-provided values with defaults using deepmerge
  controlplane_config = provider::deepmerge::mergo(
    local.controlplane_defaults,
    local.controlplane_user_values,
    "override"
  )

  # Build the complete nodes structure
  all_nodes = merge(
    {
      controlplane = merge(local.controlplane_config, {
        vmid         = local.controlplane_config.vmid,
        hostname     = local.controlplane_config.name,
        machine_type = "controlplane"
        talos_image  = var.talos_install_image_base != "" ? var.talos_install_image_base : "factory.talos.dev/nocloud-installer/${local.base_schematic_id}:${local.talos_version}"
      })
    },
    {
      for idx, worker in var.nodes.workers : "worker${idx + 1}" => merge(
        provider::deepmerge::mergo(
          local.worker_defaults,
          {
            for k, v in worker : k => v
            if v != null
          },
          "override"
        ),
        {
          vmid         = worker.vmid
          hostname     = worker.name
          machine_type = "worker"
          talos_image  = lookup(worker, "gpu_passthrough", null) != null ? (var.talos_install_image_gpu != "" ? var.talos_install_image_gpu : "factory.talos.dev/nocloud-installer/${local.gpu_schematic_id}:${local.talos_version}") : (var.talos_install_image_base != "" ? var.talos_install_image_base : "factory.talos.dev/nocloud-installer/${local.base_schematic_id}:${local.talos_version}")
        }
      )
    }
  )

  common_patches = [
    file("${path.module}/patch/cluster-init.yaml"),
    file("${path.module}/patch/sysctls-patch.yaml"),
    file("${path.module}/patch/disable-forward-dns.yaml"),
    file("${path.module}/patch/harbor-registry-patch.yaml")
  ]

  network_config = {
    for node_key, node in local.all_nodes : node_key => yamlencode({
      machine = {
        network = {
          hostname = node.hostname
          interfaces = [{
            interface = "eth0"
            dhcp      = false
            addresses = ["${node.ip}/24"]
            routes = [{
              network = "0.0.0.0/0"
              gateway = var.gateway
            }]
          }]
          nameservers = var.dns_servers
        }
        install = {
          disk  = var.talos_install_disk
          image = node.talos_image
          wipe  = var.talos_install_wipe
        }
        kubelet = {
          clusterDNS = ["10.96.0.10"] # This should match the service CIDR
        }
      }
    })
  }

  # Node-specific patches
  node_patches = merge(
    {
      controlplane = [
        file("${path.module}/patch/controlplane-ips-patch.yaml"),
        file("${path.module}/patch/etcd-quota-patch.yaml")
      ]
    },
    {
      for idx, worker in var.nodes.workers : "worker${idx + 1}" => concat(
        [file("${path.module}/patch/worker-ips-patch.yaml")],
        worker.gpu_passthrough != null ? [file("${path.module}/patch/gpu-worker-patch.yaml")] : []
      )
    }
  )

  # Generate label patches for nodes
  label_patches = merge(
    # Control plane nodes get their custom labels only
    {
      controlplane = length(local.all_nodes.controlplane.labels) > 0 ? [
        yamlencode({
          machine = {
            nodeLabels = local.all_nodes.controlplane.labels
          }
        })
      ] : []
    },
    # Worker nodes get the worker type label plus any custom labels
    {
      for node_key, node in local.all_nodes : node_key => node.machine_type == "worker" ? [
        yamlencode({
          machine = {
            nodeLabels = merge(
              { "node.kubernetes.io/type" = "worker" },
              node.labels
            )
          }
        })
      ] : [] if node.machine_type == "worker"
    }
  )
}
