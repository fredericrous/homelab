#!/bin/bash
# Script to remove unreferenced YAML files

FILES_TO_REMOVE=(
    "manifests/apps/authelia/ca-certificates-job.yaml"
    "manifests/apps/harbor/values-bitnami-tls.yaml"
    "manifests/apps/harbor/values-bitnami.yaml"
    "manifests/apps/plex/test-gpu-pod.yaml"
    "manifests/apps/stremio/harbor-registry-nodeport.yaml"
    "manifests/argocd/temp-tls-cert.yaml"
    "manifests/base/job-templates/job-generic-template.yaml"
    "manifests/core/backup/base/values-snapshot-controller.yaml"
    "manifests/core/backup/base/values-velero-custom.yaml"
    "manifests/core/backup/base/values-velero-updated.yaml"
    "manifests/core/backup/base/values-velero.yaml"
    "manifests/core/rook-ceph/values-minimal.yaml"
    "manifests/core/vault/job-vault-force-init.yaml"
)

echo "The following files will be removed:"
echo "================================="
for file in "${FILES_TO_REMOVE[@]}"; do
    if [ -f "$file" ]; then
        echo "  $file"
    fi
done

echo
read -p "Do you want to proceed with deletion? (y/N) " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    for file in "${FILES_TO_REMOVE[@]}"; do
        if [ -f "$file" ]; then
            rm -f "$file"
            echo "Removed: $file"
        fi
    done
    echo "Cleanup completed!"
else
    echo "Cleanup cancelled."
fi
