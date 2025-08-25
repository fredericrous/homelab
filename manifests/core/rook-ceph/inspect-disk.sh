#!/bin/bash
# Script to inspect disk state

echo "Inspecting disk state on worker nodes..."

for node in worker-1-gpu worker-2; do
    echo "Inspecting disk on node: $node"
    cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: inspect-disk-$node
  namespace: rook-ceph
spec:
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
        kubernetes.io/hostname: $node
      hostNetwork: true
      hostPID: true
      containers:
      - name: inspect
        image: rook/ceph:v1.15.8
        securityContext:
          privileged: true
        command: ["nsenter", "--target", "1", "--mount", "--uts", "--ipc", "--net", "--pid", "--", "bash", "-c"]
        args:
        - |
          echo "=== Disk info for /dev/sdb ==="
          fdisk -l /dev/sdb || true
          echo ""
          
          echo "=== Checking for signatures ==="
          wipefs /dev/sdb || true
          echo ""
          
          echo "=== Checking first 1MB ==="
          hexdump -C /dev/sdb | head -20 || true
          echo ""
          
          echo "=== Checking ceph-volume inventory ==="
          ceph-volume inventory /dev/sdb || true
          echo ""
          
          echo "=== Checking for bluestore label ==="
          strings /dev/sdb | grep -i bluestore | head -5 || true
          echo ""
          
          echo "=== Raw list ==="
          ceph-volume raw list || true
        volumeMounts:
        - name: dev
          mountPath: /dev
        - name: sys
          mountPath: /sys
      volumes:
      - name: dev
        hostPath:
          path: /dev
      - name: sys
        hostPath:
          path: /sys
EOF
done

echo "Waiting for inspect jobs to complete..."
sleep 30
kubectl logs -n rook-ceph job/inspect-disk-worker-1-gpu
echo ""
kubectl logs -n rook-ceph job/inspect-disk-worker-2
kubectl delete jobs -n rook-ceph inspect-disk-worker-1-gpu inspect-disk-worker-2