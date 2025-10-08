# OVH DNS Credentials for Let's Encrypt

## Overview
This document explains how to manage OVH API credentials for cert-manager's DNS-01 challenge.

## Security Notice
**NEVER commit OVH API credentials to Git!** All credentials must be stored in Vault.

## Generating New Credentials

1. Run the credential generation script:
   ```bash
   ./scripts/generate-ovh-credentials.sh
   ```

2. Follow the prompts:
   - Create an application at https://eu.api.ovh.com/createApp/
   - Enter the Application Key and Secret
   - Validate the consumer key in your browser

3. Store credentials in Vault:
   ```bash
   vault kv put secret/ovh-dns \
     applicationKey=<YOUR_KEY> \
     applicationSecret=<YOUR_SECRET> \
     consumerKey=<YOUR_CONSUMER_KEY>
   ```

## Required Permissions
The OVH API credentials need these minimal permissions:
- `GET /domain/zone/*` - List zones and records
- `PUT /domain/zone/*/record/*` - Update DNS records
- `POST /domain/zone/*/record` - Create DNS records
- `DELETE /domain/zone/*/record/*` - Delete DNS records
- `POST /domain/zone/*/refresh` - Refresh zone

## Troubleshooting

### Invalid Signature Error
This means the credentials are invalid or expired. Generate new credentials using the script above.

### Permission Denied
Check that the consumer key has been validated and has the required permissions.

### Webhook Not Available
Check that the cert-manager-webhook-ovh pod is running and the APIService is available:
```bash
kubectl get pods -n cert-manager | grep ovh
kubectl get apiservice v1alpha1.acmex.daddyshome.fr
```

## Architecture
```
┌─────────────────┐     ┌──────────────┐     ┌─────────┐
│  cert-manager   │────▶│ OVH Webhook  │────▶│ OVH API │
└─────────────────┘     └──────────────┘     └─────────┘
         │                       │
         ▼                       ▼
┌─────────────────┐     ┌──────────────┐
│ ClusterIssuer   │     │ ovh-creds    │
│ (no hardcoded)  │     │   Secret     │
└─────────────────┘     └──────────────┘
                                │
                                ▼
                        ┌──────────────┐
                        │    Vault     │
                        │ secret/ovh-dns│
                        └──────────────┘
```
