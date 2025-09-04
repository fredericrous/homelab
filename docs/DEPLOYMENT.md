# Homelab Deployment Guide

## Prerequisites

Before deploying, ensure you have:

1. **Required Tools**:
   - terraform
   - talosctl
   - kubectl
   - task (taskfile)

2. **Required Credentials**:
   ```bash
   # QNAP Vault token (from existing Vault on NAS)
   export QNAP_VAULT_TOKEN="your-qnap-vault-root-token"
   
   # OVH API credentials (for Let's Encrypt DNS challenge)
   export OVH_APPLICATION_KEY="your-app-key"
   export OVH_APPLICATION_SECRET="your-app-secret"
   export OVH_CONSUMER_KEY="your-consumer-key"
   ```

   To get OVH credentials, run:
   ```bash
   ./scripts/generate-ovh-credentials.sh
   ```

3. **Terraform Configuration**:
   ```bash
   cd terraform
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars with your settings
   ```

## Deployment

Run the complete deployment:

```bash
# With required environment variables set
QNAP_VAULT_TOKEN=xxx OVH_APPLICATION_KEY=xxx OVH_APPLICATION_SECRET=xxx OVH_CONSUMER_KEY=xxx task deploy
```

## Deployment Stages

The deployment runs through 11 stages:

1. **Stage 1**: Create VMs on Proxmox
2. **Stage 2**: Wait for VMs to get IPs via DHCP
3. **Stage 3**: Generate Talos configs with discovered IPs
4. **Stage 4**: Bootstrap Talos cluster
5. **Stage 5**: Wait for Kubernetes API
6. **Stage 6**: Deploy ArgoCD
7. **Stage 7**: Setup Vault transit token
8. **Stage 8**: Deploy core services (Storage, Vault, VSO, cert-manager)
9. **Stage 8.5**: Vault post-initialization (client CA, OVH credentials)
10. **Stage 9**: Wait for all nodes ready
11. **Stage 10**: Verify cluster
12. **Stage 11**: Post-deployment fixes

## Post-Deployment

After deployment:

1. **Access ArgoCD**:
   ```bash
   # URL
   https://argocd.daddyshome.fr
   
   # Username
   admin
   
   # Password
   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
   ```

2. **Deploy Applications**:
   ```bash
   kubectl apply -k manifests/apps/
   ```

3. **Check Cluster Health**:
   ```bash
   talosctl -n 192.168.1.67 health
   ```

## Troubleshooting

### Certificates Not Issuing

1. Check OVH credentials:
   ```bash
   kubectl get secret ovh-credentials -n cert-manager -o yaml
   ```

2. Check cert-manager webhook:
   ```bash
   kubectl get pods -n cert-manager | grep ovh
   kubectl logs -n cert-manager cert-manager-webhook-ovh-xxx
   ```

3. Check ClusterIssuer:
   ```bash
   kubectl describe clusterissuer letsencrypt-ovh-webhook
   ```

### Vault Issues

1. Check Vault status:
   ```bash
   kubectl exec -n vault vault-0 -- vault status
   ```

2. Check transit token:
   ```bash
   kubectl get secret vault-transit-token -n vault
   ```

### HAProxy Issues

1. Check client CA:
   ```bash
   kubectl get secret client-ca-cert -n haproxy-controller
   ```

2. Check ingress controller:
   ```bash
   kubectl get pods -n haproxy-controller
   kubectl get svc -n haproxy-controller
   ```
