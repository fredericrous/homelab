# mTLS Certificate Management - NAS-based Architecture

## Overview

This document describes the new centralized mTLS certificate management system using the NAS cluster as the Certificate Authority (CA) source. This architecture replaces the previous local file-based approach with a more secure, automated, and scalable solution.

## Architecture Diagram

```
┌─────────────────┐         ┌─────────────────┐         ┌─────────────────┐
│   NAS Cluster   │         │  Main Cluster   │         │     Clients     │
│                 │         │                 │         │                 │
│  ┌───────────┐  │         │  ┌───────────┐  │         │                 │
│  │   Vault   │  │ ESO     │  │   Vault   │  │         │                 │
│  │           │◄─┼─────────┼──│           │  │         │                 │
│  │ PKI/CA    │  │  Sync   │  │ client-ca │  │         │                 │
│  │ PKI/certs │  │         │  └─────┬─────┘  │         │                 │
│  └───────────┘  │         │        │ ESO    │         │                 │
│                 │         │  ┌─────▼─────┐  │         │  ┌───────────┐  │
│                 │         │  │  HAProxy  │  │ mTLS    │  │  Browser  │  │
│                 │         │  │           │◄─┼─────────┼──│   + CA    │  │
│                 │         │  │ client-ca │  │         │  │   cert    │  │
│                 │         │  └───────────┘  │         │  └───────────┘  │
└─────────────────┘         └─────────────────┘         └─────────────────┘
```

## Key Benefits

1. **Centralized Management**: All certificate operations happen in the NAS Vault
2. **GitOps Compatible**: No certificates stored in Git, only references
3. **Automated Distribution**: External Secrets Operator handles CA propagation
4. **Self-Service**: Users can download certificates via Vault CLI
5. **Audit Trail**: All certificate operations logged in Vault
6. **Disaster Recovery**: Certificates backed up with Vault snapshots

## Deployment Flow

### 1. NAS Cluster Deployment

```bash
# Deploy NAS services
task nas:deploy
```

This will:
- Deploy Vault on the NAS K3s cluster
- Initialize and unseal Vault
- Generate the PKI infrastructure
- Create admin certificate
- Generate ESO sync token

### 2. Main Cluster Deployment

```bash
# Get the ESO token from NAS
task nas:show-eso-token

# Deploy main cluster with CA sync
NAS_ESO_TOKEN=<token> task deploy
```

This will:
- Deploy the main Kubernetes cluster
- Configure External Secrets Operator
- Create ClusterSecretStore for NAS Vault
- Sync CA certificate to main Vault
- Configure HAProxy with the synced CA

### 3. Client Certificate Generation

```bash
# Generate certificate for a user
task nas:generate-client-cert -- john john@daddyshome.fr

# User downloads their certificate
export VAULT_ADDR=http://192.168.1.42:61200
vault login  # Use appropriate auth method
vault kv get -field=p12 secret/pki/clients/john | base64 -d > john.p12
```

## Technical Implementation

### NAS Vault Configuration

1. **PKI Storage Structure**:
   ```
   secret/
   ├── pki/
   │   ├── ca/           # CA certificate and key
   │   │   ├── ca.crt
   │   │   └── ca.key
   │   └── clients/      # Client certificates
   │       ├── admin/
   │       ├── john/
   │       └── ...
   └── tokens/
       └── eso-pki       # ESO sync token
   ```

2. **Vault Policies**:
   - `eso-pki-reader`: Read-only access to PKI paths for ESO
   - User policies for certificate download

### External Secrets Configuration

1. **ClusterSecretStore** (`nas-vault-backend`):
   - Points to NAS Vault at `http://192.168.1.42:61200`
   - Uses token authentication
   - Token stored in `nas-vault-token` secret

2. **ExternalSecret** (`sync-ca-from-nas`):
   - Syncs from `secret/data/pki/ca`
   - Refreshes every 5 minutes
   - Creates temporary secret for processing

3. **Sync Job**:
   - Reads CA from ESO-created secret
   - Pushes to main Vault at `secret/client-ca`
   - Maintains compatibility with existing setup

### HAProxy Integration

1. **ExternalSecret** (`client-ca-cert`):
   - Reads from main Vault `secret/client-ca`
   - Creates Opaque secret with `ca.crt` key
   - HAProxy uses for client verification

## Migration Strategy

### Phase 1: Parallel Operation
- Deploy new NAS-based PKI
- Keep existing CA in place
- Test with new certificates

### Phase 2: Gradual Migration
- Issue new certificates from NAS
- Update HAProxy to trust both CAs temporarily
- Migrate users as certificates expire

### Phase 3: Deprecation
- Remove old CA from HAProxy trust
- Archive old certificate files
- Document new process

## Operational Procedures

### Adding a New User

```bash
# On NAS management workstation
export VAULT_ADDR=http://192.168.1.42:61200
vault login  # Admin token

# Generate certificate
source /nas/scripts/generate-pki.sh
generate_client_cert "username" "user@daddyshome.fr"

# User downloads certificate
vault kv get -field=p12 secret/pki/clients/username | base64 -d > username.p12
```

### Certificate Renewal

```bash
# Re-run generation (will create new cert)
generate_client_cert "username" "user@daddyshome.fr"

# Old certificate remains valid until expiration
```

### Monitoring Certificate Expiration

```bash
# List all client certificates with creation date
vault kv list secret/pki/clients | while read user; do
  created=$(vault kv get -field=created secret/pki/clients/$user)
  echo "$user: $created"
done
```

## Security Considerations

1. **Network Security**:
   - Firewall rules between clusters
   - Consider TLS for Vault connections
   - VPN for remote access

2. **Access Control**:
   - Separate tokens for different operations
   - Minimal permissions for ESO
   - Audit logging enabled

3. **Key Protection**:
   - CA private key never leaves NAS Vault
   - Client keys generated in memory
   - No keys in Git repositories

## Troubleshooting

### CA Not Syncing

```bash
# Check ClusterSecretStore
kubectl get clustersecretstore nas-vault-backend -o yaml

# Check ExternalSecret
kubectl get externalsecret sync-ca-from-nas -n vault -o yaml

# Check network connectivity
kubectl run test-curl --rm -it --image=curlimages/curl -- \
  curl -v http://192.168.1.42:61200/v1/sys/health
```

### Certificate Not Working

```bash
# Verify CA in HAProxy
kubectl get secret client-ca-cert -n haproxy-controller -o yaml

# Check certificate format
openssl x509 -in client.crt -text -noout

# Test with curl
curl --cert client.crt --key client.key --cacert ca.crt \
  https://argocd.daddyshome.fr
```

## Future Enhancements

1. **Web Portal**: Self-service UI for certificate management
2. **ACME Protocol**: Automated certificate enrollment
3. **Short-lived Certificates**: Reduce validity to hours
4. **Certificate Transparency**: Public audit log
5. **Hardware Security Module**: Store CA in HSM

## Commands Reference

```bash
# NAS Tasks
task nas:deploy              # Deploy NAS cluster
task nas:vault-pki           # Initialize PKI
task nas:generate-client-cert -- <user> <email>  # Generate cert
task nas:show-eso-token      # Show ESO sync token

# Main Cluster Tasks
NAS_ESO_TOKEN=<token> task deploy  # Deploy with CA sync
task configure-nas-sync -- <token>  # Configure sync manually
task check-ca-sync           # Verify CA synchronization

# Certificate Download
export VAULT_ADDR=http://192.168.1.42:61200
vault login
vault kv get -field=p12 secret/pki/clients/<user> | base64 -d > <user>.p12
```