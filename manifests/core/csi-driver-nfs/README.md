# NFS CSI Driver

This directory contains the Kubernetes NFS CSI driver deployment using the official Helm chart.

## Overview

The NFS CSI driver enables dynamic provisioning of NFS volumes in Kubernetes. It replaces the SMB CSI driver for better compatibility and performance.

## Configuration

- **Server**: 192.168.1.42
- **Shares**: 
  - `/Media` - Media storage (nfs-media storage class)
  - `/VMs` - Virtual machine storage (nfs-vms storage class)
- **Credentials**: Stored in Vault at `secret/nfs` with the same username/password as SMB

## Migration from SMB CSI Driver

When migrating from SMB to NFS:

1. **Update PVCs**: Change storageClassName from `smb-media`/`smb-vms` to `nfs-media`/`nfs-vms`
2. **Update Secrets**: Change secret references from `smbcreds` to `nfscreds`
3. **Data Migration**: You'll need to copy data from SMB volumes to NFS volumes manually

## Storage Classes

Two storage classes are created:

- `nfs-media`: For media files (photos, videos, etc.)
- `nfs-vms`: For virtual machine disks and backups

## Troubleshooting

1. **Mount failures**: Check that NFS is enabled on the server and the export paths are correct
2. **Permission issues**: Ensure the NFS server allows the Kubernetes nodes' IPs
3. **Authentication**: Verify credentials in Vault at `secret/nfs`

## References

- [CSI Driver NFS GitHub](https://github.com/kubernetes-csi/csi-driver-nfs)
- [Helm Chart Documentation](https://github.com/kubernetes-csi/csi-driver-nfs/tree/master/charts)