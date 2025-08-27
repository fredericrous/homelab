locals {
  all_nodes = merge(
    {
      controlplane = {
        vmid            = 100
        hostname        = "talos-cp-1"
        ip              = var.nodes.controlplane.ip
        mac_address     = var.nodes.controlplane.mac_address
        cores           = 2
        memory          = 12288
        os_disk_size    = 32
        data_disk_size  = null
        gpu_passthrough = null
        machine_type    = "controlplane"
        talos_image     = var.talos_install_image_base != "" ? var.talos_install_image_base : "factory.talos.dev/nocloud-installer/${local.base_schematic_id}:${local.talos_version}"
        labels          = var.nodes.controlplane.labels
      }
    },
    {
      for idx, worker in var.nodes.workers : "worker${idx + 1}" => {
        vmid            = worker.vmid
        hostname        = worker.name
        ip              = worker.ip
        mac_address     = worker.mac_address
        cores           = worker.cores
        memory          = worker.memory
        os_disk_size    = worker.os_disk_size
        data_disk_size  = worker.data_disk_size
        gpu_passthrough = worker.gpu_passthrough
        machine_type    = "worker"
        talos_image     = worker.gpu_passthrough != null ? (var.talos_install_image_gpu != "" ? var.talos_install_image_gpu : "factory.talos.dev/nocloud-installer/${local.gpu_schematic_id}:${local.talos_version}") : (var.talos_install_image_base != "" ? var.talos_install_image_base : "factory.talos.dev/nocloud-installer/${local.base_schematic_id}:${local.talos_version}")
        labels          = worker.labels
      }
    }
  )

  common_patches = [
    file("${path.module}/patch/cluster-init.yaml"),
    file("${path.module}/patch/sysctls-patch.yaml"),
    file("${path.module}/patch/disable-forward-dns.yaml")
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
          clusterDNS = ["10.96.0.10"]
        }
      }
    })
  }

  # Node-specific patches
  node_patches = merge(
    {
      controlplane = [
        file("${path.module}/patch/controlplane-ips-patch.yaml")
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
