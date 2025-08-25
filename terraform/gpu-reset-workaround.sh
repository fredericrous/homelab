#!/bin/bash
# GPU Reset Workaround Script for RTX 4060

# This script implements various workarounds for GPU reset issues

echo "GPU Reset Workarounds for RTX 4060"
echo "=================================="

# Option 1: Vendor Reset Module
echo ""
echo "Option 1: Install vendor-reset module (recommended)"
echo "This helps with GPU reset issues:"
echo ""
echo "apt update"
echo "apt install dkms build-essential"
echo "git clone https://github.com/gnif/vendor-reset.git"
echo "cd vendor-reset"
echo "dkms install ."
echo "echo 'vendor-reset' >> /etc/modules"
echo "update-initramfs -u"
echo ""

# Option 2: Kernel Parameters
echo "Option 2: Add kernel parameters"
echo "Edit /etc/default/grub and add to GRUB_CMDLINE_LINUX_DEFAULT:"
echo ""
echo "pcie_acs_override=downstream,multifunction nofb video=vesafb:off video=efifb:off"
echo ""
echo "Then run: update-grub && update-initramfs -u"
echo ""

# Option 3: Hook Scripts
echo "Option 3: Create VM hook scripts"
echo "Create /var/lib/vz/snippets/gpu-hookscript.pl:"
echo ""
cat << 'EOF'
#!/usr/bin/perl

use strict;
use warnings;

print "GUEST HOOK: " . join(' ', @ARGV). "\n";

# First argument is the vmid
my $vmid = shift;

# Second argument is the phase
my $phase = shift;

if ($phase eq 'pre-start') {
    print "Preparing GPU for VM $vmid\n";
    
    # Remove GPU from vfio-pci
    system("echo 1 > /sys/bus/pci/devices/0000:01:00.0/remove");
    system("echo 1 > /sys/bus/pci/devices/0000:01:00.1/remove");
    sleep(1);
    
    # Rescan PCI bus
    system("echo 1 > /sys/bus/pci/rescan");
    sleep(2);
    
} elsif ($phase eq 'post-stop') {
    print "Resetting GPU after VM $vmid stopped\n";
    
    # Try to reset the device
    system("echo 1 > /sys/bus/pci/devices/0000:01:00.0/reset 2>/dev/null");
    system("echo 1 > /sys/bus/pci/devices/0000:01:00.1/reset 2>/dev/null");
}

exit(0);
EOF

echo ""
echo "chmod +x /var/lib/vz/snippets/gpu-hookscript.pl"
echo ""
echo "Then add to VM config:"
echo "qm set 101 --hookscript local:snippets/gpu-hookscript.pl"
echo ""

# Option 4: Alternative GPU ROM
echo "Option 4: Try GPU ROM without UEFI support"
echo "Some RTX 4060 ROMs have issues with UEFI. Try:"
echo "1. Dump a legacy BIOS ROM (not UEFI)"
echo "2. Or download from TechPowerUp VGA BIOS collection"
echo "3. Place in /usr/share/kvm/"
echo ""

# Option 5: Disable GPU ROM entirely
echo "Option 5: Try without ROM file"
echo "Remove rom_file from GPU passthrough config and test"
echo ""

# Option 6: MSI interrupts
echo "Option 6: Enable MSI interrupts"
echo "Add to VM args:"
echo "-global kvm-pit.lost_tick_policy=discard"
echo ""

echo "Additional debugging:"
echo "- Check 'dmesg -w' while starting VM"
echo "- Try 'lspci -vvv -s 01:00' to see GPU state"
echo "- Monitor /var/log/syslog during VM start"