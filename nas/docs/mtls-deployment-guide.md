# mTLS Deployment Guide - NAS-based Architecture

## Overview

This guide covers deploying the new centralized mTLS certificate management system using the NAS cluster as the certificate authority.

## Prerequisites

- NAS cluster deployed with Vault
- External Secrets Operator in both clusters
- Network connectivity between clusters
- Vault CLI installed locally

## Step 1: Configure NAS Vault PKI

1. **Enable KV v2 secret engine** (if not already enabled):
   ```bash
   vault secrets enable -version=2 -path=secret kv
   ```

2. **Create PKI paths**:
   ```bash
   vault kv put secret/pki/ca placeholder=true
   vault kv put secret/pki/clients placeholder=true
   ```

3. **Create policy for ESO access**:
   ```hcl
   # eso-pki-reader policy
   path "secret/data/pki/ca" {
     capabilities = ["read"]
   }
   ```

4. **Generate ESO access token**:
   ```bash
   vault token create -policy=eso-pki-reader -ttl=8760h
   ```

## Step 2: Deploy PKI Generation

1. **Run PKI generation script**:
   ```bash
   export VAULT_ADDR=http://nas-vault:8200
   export VAULT_TOKEN=<admin-token>
   ./nas/scripts/generate-pki.sh
   ```

2. **Verify CA creation**:
   ```bash
   vault kv get secret/pki/ca
   ```

## Step 3: Configure Cross-Cluster Sync

1. **Deploy ClusterSecretStore in main cluster**:
   ```bash
   # Update the token in the secret
   kubectl apply -f manifests/core/external-secrets-operator/clustersecretstore-nas-vault.yaml
   ```

2. **Deploy CA sync ExternalSecret**:
   ```bash
   kubectl apply -f manifests/core/client-ca/externalsecret-ca-from-nas.yaml
   ```

3. **Verify sync**:
   ```bash
   kubectl get externalsecret -n vault sync-ca-from-nas
   kubectl get secret -n haproxy-controller client-ca-cert
   ```

## Step 4: User Certificate Distribution

1. **Generate user certificate**:
   ```bash
   # On NAS cluster
   source generate_client_cert "username" "user@daddyshome.fr"
   ```

2. **User downloads certificate**:
   ```bash
   # User runs this locally
   export VAULT_ADDR=http://nas-vaultx.daddyshome.fr:8200
   vault login  # Use user token or LDAP
   vault kv get -field=p12 secret/pki/clients/username | base64 -d > username.p12
   ```

## Step 5: Migration from Old System

1. **Parallel operation period**:
   - Keep old CA in place
   - Issue new certificates from NAS
   - Both CAs trusted by HAProxy

2. **Update HAProxy to trust both CAs**:
   ```yaml
   # Temporary during migration
   data:
     ca.crt: |
       {{ old_ca }}
       {{ new_ca }}
   ```

3. **Gradual user migration**:
   - Track certificate expiration
   - Issue new certs from NAS
   - Remove old CA after all migrated

## Monitoring and Alerting

1. **ESO sync monitoring**:
   ```yaml
   - alert: ExternalSecretSyncFailure
     expr: externalsecret_sync_calls_error{name="sync-ca-from-nas"} > 0
   ```

2. **Certificate expiration**:
   ```bash
   # Check cert expiration in Vault
   vault kv get secret/pki/clients/username | jq '.data.data.created'
   ```

## Troubleshooting

### Sync not working
1. Check ClusterSecretStore status
2. Verify network connectivity
3. Check Vault token permissions

### Certificate not accepted
1. Verify CA is synced to HAProxy
2. Check certificate validity dates
3. Ensure correct certificate format

## Security Considerations

1. **Network Security**:
   - Use TLS for Vault connections
   - Firewall rules between clusters
   - Consider VPN or private network

2. **Access Control**:
   - Separate tokens for ESO sync
   - User policies for cert download
   - Audit logging enabled

3. **Backup and Recovery**:
   - Backup NAS Vault regularly
   - Store CA backup securely
   - Document recovery procedures
