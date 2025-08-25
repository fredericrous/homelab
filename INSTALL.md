# install proxmox in baremetal

download proxmox https://www.proxmox.com/en/downloads/proxmox-virtual-environment/iso

install it

if the install hangs, you certainly need to add nomodeset to the grub file https://pve.proxmox.com/wiki/Installation#nomodeset_kernel_param

once installation is done, navigate to https://<baremetal-server-ip>:8006/ (where 66 is your ip address)

# configure gpu passthrough on proxmox

from Data Center > proxmox > Shell, find the id of the graphic card:

```
lspci -nnk | grep -A3 -i nvidia
01:00.0 VGA compatible controller [0300]: NVIDIA Corporation AD107 [GeForce RTX 4060] [10de:2882] (rev a1)
        Subsystem: Gigabyte Technology Co., Ltd AD107 [GeForce RTX 4060] [1458:4116]
        Kernel modules: nvidiafb, nouveau
01:00.1 Audio device [0403]: NVIDIA Corporation AD107 High Definition Audio Controller [10de:22be] (rev a1)
```

ids in this example are 10de:2882 and 10de:22be

/etc/modprobe.d/vfio.conf
options vfio-pci ids=10de:2882,10de:22be disable_vga=1 disable_idle_d3=1

disable_idle_d3=1 is what makes vm reset work when gpu passthrough is enabled on rtx 4060 low profile

/etc/modprobe.d/blacklist-nvidia.conf
nvidiafb
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nouveau

/etc/modules-load.d/vfio.conf
vfio
vfio_iommu_type1
vfio_pci

Edit /etc/default/grub → GRUB_CMDLINE_LINUX_DEFAULT:
amd_iommu=on iommu=pt video=efifb:off

Then:

update-grub
update-initramfs -u -k all
reboot

# resolve proxmox webui intempestive logout

nameserver defaults to 127.0.0.1. we should change that

nano /etc/resolv.conf

add for example

nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 192.168.1.1

now install a ntp service, this avoid getting disconnected while using proxmox because of invalid pve ticket

apt update
apt install chrony
systemctl enable chrony --now


# create vm and install talos to host kubernetes
note, talos-controller-ip in this guide is 192.168.1.67

go to https://factory.talos.dev/ generate an iso with amd-ucode extension

upload the iso from Data Center > proxmox > local > ISO Images

create 3 vms, one for the controller, and two workers, one of these worker has gpu passthrough.
look at create-vm-proxmox.sh to get commands you can copy paste under Data Center > proxmox > Shell
** the gpu worker node fails to restart? reboot the whole proxmox machine :'(

then run

talosctl gen config homelab https://192.168.1.67:6443

**sidenote: initially I used the command above but now I'm using talhelper, and command should therefore be talhelper genconfig (once talconfig has been updated and talsecret regenerated)

make sure the ip is correct by comparing the mac address of the vm with the one set on your router at http://192.168.1.1/

edit the controlplane.yaml file:
- set machine.install.image with the id gotten under section Upgrading Talos Linux of factory.talos.dev
- set machine.network.interfaces[] with eth0 and an ip you chose

talosctl --talosconfig talosconfig \
        apply-config --insecure --nodes 192.168.1.67 \
        --file controlplane.yaml

do the same for the workers.

talosctl --talosconfig talosconfig \
        apply-config --insecure --nodes 192.168.1.x \
        --file worker.yaml

finaly run

talosctl --talosconfig talosconfig bootstrap --nodes 192.168.1.67 -e 192.168.1.67

# edit talos config ip address

get the network id interface with command

talosctl --talosconfig talosconfig -e 192.168.1.67 -n 192.168.1.67 get links -o yaml

then edit `interface-ip-patch.yaml` with the id of the interface and the desired ip address and run

talosctl --talosconfig talosconfig patch mc --nodes 192.168.1.67 --patch @patch/interface-ip-patch.yaml

do a search replace all to look for the old ip and replace with the new one

# edit talos 

run all-nodes.yaml against controlplane and workers
run controlplane-patch on controlplane
run workers-patch on workers

# edit talos gpu worker config

for the gpu, go again to https://factory.talos.dev/ generate an iso with amd-ucode extension and nvidia extensions nvidia and kmod like described at https://www.talos.dev/v1.10/talos-guides/configuration/nvidia-gpu-proprietary/

run

talosctl --talosconfig talosconfig patch mc --patch @gpu-worker-patch.yaml --nodes 192.168.1.68 -e 192.168.1.67:6443


* to automate all this, a path to explore is terraform, like there https://github.com/zimmertr/TJs-Kubernetes-Service/

# replace flannel cni with cilium

talosctl --talosconfig talosconfig patch mc --patch @disable-proxy-flannel.yaml --nodes 192.168.1.67,192.168.1.68,192.168.1.69 -e 192.168.1.67:6443

kubectl scale daemonset kube-proxy -n kube-system --replicas=0
