#!/bin/bash
# NVIDIA RTX 4060 GPU Passthrough Fix Script

echo "NVIDIA RTX 4060 Reset Fix"
echo "========================="

# 1. Ensure NVIDIA drivers are blacklisted
echo "Step 1: Verifying NVIDIA driver blacklist..."
echo ""
echo "Check /etc/modprobe.d/blacklist-nvidia.conf contains:"
echo "blacklist nouveau"
echo "blacklist nvidia"
echo "blacklist nvidia_drm"
echo "blacklist nvidia_modeset"
echo "blacklist nvidiafb"
echo ""

# 2. Add VFIO early binding
echo "Step 2: Configure early VFIO binding"
echo "Add to /etc/modprobe.d/vfio.conf:"
echo "options vfio-pci ids=10de:2882,10de:22be disable_vga=1"
echo "softdep nouveau pre: vfio-pci"
echo "softdep nvidia pre: vfio-pci"
echo "softdep nvidia* pre: vfio-pci"
echo ""

# 3. Configure proper PCI reset
echo "Step 3: Add kernel parameters for better reset"
echo "Edit /etc/default/grub and add to GRUB_CMDLINE_LINUX_DEFAULT:"
echo ""
echo "pci=realloc=off"
echo ""
echo "This prevents PCI BAR reallocation which can cause issues"
echo ""

# 4. Create systemd service for GPU reset
echo "Step 4: Create GPU reset service"
cat > /tmp/nvidia-gpu-reset.service << 'EOF'
[Unit]
Description=NVIDIA GPU Reset Workaround
Before=pve-guests.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nvidia-gpu-reset.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

echo "Save this to: /etc/systemd/system/nvidia-gpu-reset.service"
echo ""

# 5. Create the reset script
cat > /tmp/nvidia-gpu-reset.sh << 'EOF'
#!/bin/bash
# NVIDIA GPU Reset Script

GPU_ID="0000:01:00"
echo "Resetting NVIDIA GPU at $GPU_ID"

# Remove devices
echo 1 > /sys/bus/pci/devices/${GPU_ID}.0/remove 2>/dev/null
echo 1 > /sys/bus/pci/devices/${GPU_ID}.1/remove 2>/dev/null
sleep 2

# Rescan PCI bus
echo 1 > /sys/bus/pci/rescan
sleep 3

# Ensure VFIO-PCI driver is bound
echo "10de 2882" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null
echo "10de 22be" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null

echo "GPU reset complete"
EOF

echo "Save this to: /usr/local/bin/nvidia-gpu-reset.sh"
echo "chmod +x /usr/local/bin/nvidia-gpu-reset.sh"
echo ""

# 6. Alternative: Use nvidia-smi persistence mode
echo "Step 5: Alternative - Try without GPU in first boot"
echo "For RTX 4060, sometimes it works better to:"
echo "1. Start VM without GPU"
echo "2. Shut down VM"
echo "3. Add GPU and start again"
echo ""

# 7. QEMU args for NVIDIA
echo "Step 6: Add QEMU arguments (if needed)"
echo "Add to VM configuration:"
echo "args: -cpu host,kvm=off,hv_vendor_id=proxmox"
echo ""
echo "The 'kvm=off' hides KVM from NVIDIA driver (Error 43 workaround)"
echo ""

echo "Step 7: After applying changes:"
echo "update-grub"
echo "update-initramfs -u"
echo "systemctl enable nvidia-gpu-reset.service"
echo "reboot"
echo ""

echo "Debugging commands:"
echo "lspci -nnk -s 01:00"
echo "cat /sys/bus/pci/devices/0000:01:00.0/reset_method"
echo "dmesg | grep -i vfio"