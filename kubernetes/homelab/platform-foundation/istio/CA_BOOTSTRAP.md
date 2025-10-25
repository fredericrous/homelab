# Istio Root CA Bootstrap (Homelab <-> NAS)

This folder contains the automation for bootstrapping and distributing a shared Istio CA between the homelab and NAS clusters. The implementation uses a Vault-independent approach to avoid circular dependencies (Vault needs NAS for transit unseal, but Istio needs CA to establish connectivity).

## Architecture Overview

1. **Direct CA Generation (`istio-ca-bootstrap`)**
   * Runs as a Kubernetes Job in the homelab cluster
   * Generates a 4096-bit RSA root certificate valid for 1 year (improved rotation)
   * Creates the `cacerts` secret directly in `istio-system` namespace
   * Idempotent with comprehensive validation:
     - Validates existing certificates before regeneration
     - Creates automatic backups before any modifications
     - Uses atomic operations to prevent race conditions
     - Performs certificate validation (expiry, key size, CA flag, key matching)
   * Structured JSON logging for better observability
   * Generation tracking with annotations

2. **Automated CA Sync to NAS**
   * The `istio-ca-sync-to-nas` job automatically syncs the CA to NAS
   * NAS kubeconfig is sourced from Vault via ExternalSecrets (no manual kubectl apply)
   * Validates fingerprints match before and after sync
   * Adds metadata annotations for tracking

3. **Vault Backup (Optional)**
   * A CronJob (`istio-ca-vault-backup`) runs daily
   * When Vault becomes available, it backs up the CA
   * Provides long-term storage and potential ExternalSecret integration

4. **No Circular Dependencies**
   * CA bootstrap doesn't depend on Vault
   * Istio can start with the CA secret
   * Vault can use transit unseal via direct IP
   * Once everything is up, services can use Istio mesh

## Vault Prerequisites

### 1. Create the Vault Policy

Create a policy file `istio-ca-policy.hcl`:

```hcl
# Policy for Istio CA bootstrap job (write access)
path "secret/data/istio/ca" {
  capabilities = ["create", "read", "update", "patch"]
}

# Policy for Istio CA sync (read-only access)  
path "secret/data/istio/ca" {
  capabilities = ["read"]
}
```

Apply the policy:

```bash
vault policy write istio-ca-bootstrap istio-ca-policy.hcl
vault policy write istio-ca-sync istio-ca-policy.hcl
```

### 2. Configure Kubernetes Auth Roles

Enable Kubernetes auth if not already enabled:

```bash
vault auth enable kubernetes
```

Create the auth roles for both clusters:

```bash
# Role for homelab bootstrap job
vault write auth/kubernetes/role/istio-ca-bootstrap \
  bound_service_account_names=istio-ca-bootstrap \
  bound_service_account_namespaces=istio-system \
  policies=istio-ca-bootstrap \
  ttl=1h

# Role for NAS sync (needs to authenticate from NAS cluster)
vault write auth/kubernetes/role/istio-ca-sync \
  bound_service_account_names=istio-ca-sync \
  bound_service_account_namespaces=istio-system \
  policies=istio-ca-sync \
  ttl=24h
```

## Deployment Steps

### 1. Bootstrap CA on Homelab Cluster

```bash
# Apply the CA bootstrap resources
kubectl --kubeconfig kubeconfig apply -k kubernetes/homelab/platform-foundation/istio/ca-bootstrap/

# Wait for the job to complete
kubectl --kubeconfig kubeconfig -n istio-system wait --for=condition=complete job/istio-ca-bootstrap --timeout=2m

# Verify the secret was created
kubectl --kubeconfig kubeconfig -n istio-system get secret cacerts
```

### 2. Sync CA to NAS Cluster

The CA sync is now automated inside `bootstrap homelab bootstrap` (it calls the script below). You can also run it manually if you need to re-sync outside the bootstrap flow:

```bash
# Run the automated CA setup script
./bootstrap/scripts/homelab/ensure-istio-ca.sh

# This script will:
# 1. Push the NAS kubeconfig to Vault (secret/kubeconfigs/nas) — the script will read VAULT_TOKEN from .env or the vault-admin secret automatically
# 2. Trigger the CA bootstrap job
# 3. Wait for the CA to be generated
# 4. Automatically sync the CA to NAS
# 5. Verify fingerprints match
# 6. Reconcile Istio components
```

Manual verification:
```bash
# Verify the secret was created in both clusters
kubectl --kubeconfig kubeconfig -n istio-system get secret cacerts
kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml -n istio-system get secret cacerts
```

### 3. Verify CA Consistency

```bash
# Compare CA fingerprints between clusters
HOMELAB_CA=$(kubectl --kubeconfig kubeconfig -n istio-system get secret cacerts -o jsonpath='{.data.root-cert\.pem}' | base64 -d | openssl x509 -fingerprint -noout)
NAS_CA=$(kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml -n istio-system get secret cacerts -o jsonpath='{.data.root-cert\.pem}' | base64 -d | openssl x509 -fingerprint -noout)

echo "Homelab CA: $HOMELAB_CA"
echo "NAS CA:     $NAS_CA"
```

### 4. Reconcile Istio Components

```bash
# Reconcile Istio deployments
flux --kubeconfig kubeconfig reconcile helmrelease istio-base -n flux-system
flux --kubeconfig kubeconfig reconcile helmrelease istiod -n flux-system
flux --kubeconfig infrastructure/nas/kubeconfig.yaml reconcile helmrelease istio-eastwestgateway -n flux-system
```

## Troubleshooting

### Understanding the Circular Dependency

The system has a circular dependency that this bootstrap process resolves:
- Homelab Vault needs NAS Vault for transit unseal
- NAS connectivity through Istio needs the shared CA
- CA generation originally needed Vault

This is why we generate the CA directly as a Kubernetes secret first, then optionally back it up to Vault later.

### CA Bootstrap Job Failed

Check the job logs:
```bash
kubectl --kubeconfig kubeconfig -n istio-system logs job/istio-ca-bootstrap
```

Common issues:
- Namespace doesn't exist
- ServiceAccount missing permissions
- Job already completed (secret exists)

### Manual CA Copy Failed

If the manual copy between clusters fails:
```bash
# Ensure istio-system namespace exists on NAS
kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml create ns istio-system

# Check for existing secret
kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml get secret cacerts -n istio-system

# Force replace if needed
kubectl --kubeconfig kubeconfig get secret cacerts -n istio-system -o yaml | \
  kubectl --kubeconfig infrastructure/nas/kubeconfig.yaml replace -f -
```

### Vault Backup Not Running

The Vault backup is optional and only runs when Vault is healthy:
```bash
# Check CronJob status
kubectl --kubeconfig kubeconfig -n istio-system get cronjob istio-ca-vault-backup

# Check recent job runs
kubectl --kubeconfig kubeconfig -n istio-system get jobs -l job-name=istio-ca-vault-backup

# View logs of a backup job
kubectl --kubeconfig kubeconfig -n istio-system logs job/istio-ca-vault-backup-<timestamp>
```

### Vault Still Using Direct IP

This is intentional! The Vault transit unseal configuration should continue using the direct IP to NAS:
```yaml
seal "transit" {
  address = "http://192.168.1.42:61200"  # This should NOT be changed
  # ...
}
```

Only application-level access should use the Istio service mesh addresses.

## Security Improvements

The CA bootstrap job includes several security enhancements:

### 1. Atomic Operations
- Uses `kubectl patch` with merge operations to prevent race conditions
- Ensures updates are atomic and consistent

### 2. Automatic Backups
- Creates timestamped backups before modifying existing CAs
- Backup secrets are named `cacerts-backup-{timestamp}`
- Prevents data loss if regeneration fails

### 3. Comprehensive Validation
- **Certificate format**: Validates X.509 structure
- **CA flag**: Ensures certificate has `CA:TRUE` extension
- **Key matching**: Verifies private key matches certificate
- **Expiry check**: Warns if certificate expires in less than 30 days
- **Key size**: Ensures minimum 4096-bit RSA keys
- **Generation tracking**: Maintains generation counter in annotations

### 4. Improved Observability
- Structured JSON logging for easier parsing
- Generation tracking with timestamps
- Detailed error messages for troubleshooting

### Example Log Output
```json
{"timestamp":"2024-01-15T10:30:00Z","level":"INFO","message":"Starting Istio CA bootstrap process"}
{"timestamp":"2024-01-15T10:30:01Z","level":"INFO","message":"Found existing cacerts secret, validating..."}
{"timestamp":"2024-01-15T10:30:02Z","level":"INFO","message":"Certificate validation passed"}
{"timestamp":"2024-01-15T10:30:02Z","level":"INFO","message":"Existing CA is valid (generation: 2), exiting"}
```

### Monitoring Backup Secrets
```bash
# List all CA backup secrets
kubectl --kubeconfig kubeconfig -n istio-system get secrets | grep cacerts-backup

# View a specific backup
kubectl --kubeconfig kubeconfig -n istio-system get secret cacerts-backup-1705315800 -o yaml
```
