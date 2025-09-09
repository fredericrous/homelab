# Vault Transit Unseal Operator - Feature Roadmap

## Current Features
- ✅ Auto-unseal using transit backend
- ✅ Watch for sealed Vault instances
- ✅ Handle pod restarts

## Proposed Features for Full Lifecycle Management

### 1. Initialization Management
```go
// Handle first-time Vault initialization
type VaultInitialization struct {
    AutoInit         bool   `json:"autoInit,omitempty"`
    SecretShares     int    `json:"secretShares,omitempty"`
    SecretThreshold  int    `json:"secretThreshold,omitempty"`
    StoreRootToken   bool   `json:"storeRootToken,omitempty"`
    RootTokenSecret  string `json:"rootTokenSecret,omitempty"`
}
```

**Features:**
- Auto-initialize on first deployment
- Store root token and recovery keys in K8s secrets
- Support for different initialization strategies

### 2. Configuration Management
```yaml
apiVersion: vault.banzaicloud.com/v1alpha1
kind: VaultConfiguration
metadata:
  name: vault-config
spec:
  vault:
    address: http://vault:8200
  auth:
    kubernetes:
      enabled: true
      config:
        kubernetes_host: "https://kubernetes.default.svc"
  secretEngines:
    - path: secret
      type: kv-v2
      description: "KV v2 secret engine"
      config:
        version: "2"
    - path: pki
      type: pki
      description: "PKI secret engine"
  policies:
    - name: external-secrets-operator
      rules: |
        path "secret/*" {
          capabilities = ["read", "list"]
        }
  auditDevices:
    - type: file
      path: /vault/logs/audit.log
```

### 3. Authentication Methods
```yaml
spec:
  auth:
    kubernetes:
      enabled: true
      roles:
        - name: external-secrets-operator
          bound_service_account_names: ["external-secrets"]
          bound_service_account_namespaces: ["external-secrets"]
          policies: ["external-secrets-operator"]
          ttl: 24h
    ldap:
      enabled: true
      url: "ldap://lldap.lldap.svc:3890"
      userdn: "ou=people,dc=daddyshome,dc=fr"
      groupdn: "ou=groups,dc=daddyshome,dc=fr"
    approle:
      enabled: true
      roles:
        - name: argocd
          policies: ["argocd-policy"]
```

### 4. Secret Population
```yaml
apiVersion: vault.banzaicloud.com/v1alpha1
kind: VaultSecret
metadata:
  name: initial-secrets
spec:
  vault:
    address: http://vault:8200
  secrets:
    - path: secret/argocd/ldap
      data:
        ldap_bindDN: "uid=argocd,ou=people,dc=daddyshome,dc=fr"
        ldap_bindPW: "${LDAP_PASSWORD}" # From K8s secret
    - path: secret/postgres/superuser
      data:
        username: postgres
        password: "${POSTGRES_PASSWORD}"
```

### 5. Backup and Restore
```yaml
apiVersion: vault.banzaicloud.com/v1alpha1
kind: VaultBackup
metadata:
  name: vault-backup
spec:
  schedule: "0 2 * * *"  # Daily at 2 AM
  storage:
    s3:
      bucket: vault-backups
      prefix: homelab/
      credentialsSecret: s3-credentials
  retention:
    keepLast: 7
    keepDaily: 7
    keepWeekly: 4
```

### 6. Health and Monitoring
```go
// Enhanced health checks
type VaultHealth struct {
    Status           string            `json:"status"`
    Initialized      bool              `json:"initialized"`
    Sealed           bool              `json:"sealed"`
    Version          string            `json:"version"`
    ClusterID        string            `json:"clusterId"`
    LastBackup       *metav1.Time      `json:"lastBackup,omitempty"`
    ConfiguredAuths  []string          `json:"configuredAuths,omitempty"`
    ConfiguredMounts []string          `json:"configuredMounts,omitempty"`
    Metrics          map[string]string `json:"metrics,omitempty"`
}
```

### 7. Multi-Cluster Support
```yaml
apiVersion: vault.banzaicloud.com/v1alpha1
kind: VaultCluster
metadata:
  name: vault-primary
spec:
  replicas: 3
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
  replication:
    mode: performance
    primary: true
```

### 8. PKI Management
```yaml
apiVersion: vault.banzaicloud.com/v1alpha1
kind: VaultPKI
metadata:
  name: internal-ca
spec:
  mount: pki
  rootCA:
    commonName: "Homelab Internal CA"
    ttl: 87600h # 10 years
  intermediateCAs:
    - name: apps-ca
      commonName: "Apps Intermediate CA"
      ttl: 43800h # 5 years
  roles:
    - name: homelab-cert
      allowed_domains: ["*.daddyshome.fr"]
      allow_subdomains: true
      ttl: 720h # 30 days
```

### 9. Dynamic Database Credentials
```yaml
apiVersion: vault.banzaicloud.com/v1alpha1
kind: VaultDatabase
metadata:
  name: postgres-dynamic
spec:
  mount: database
  config:
    plugin_name: postgresql-database-plugin
    connection_url: "postgresql://{{username}}:{{password}}@postgres:5432/postgres"
    credentialsSecret: postgres-superuser
  roles:
    - name: readonly
      db_name: postgres
      creation_statements: |
        CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
        GRANT SELECT ON ALL TABLES IN SCHEMA public TO "{{name}}";
      default_ttl: 1h
      max_ttl: 24h
```

### 10. GitOps Integration
```yaml
apiVersion: vault.banzaicloud.com/v1alpha1
kind: VaultGitOps
metadata:
  name: vault-config-sync
spec:
  source:
    git:
      url: https://github.com/fredericrous/homelab
      branch: main
      path: vault-config/
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=false
```

## Implementation Priority

1. **Phase 1: Core Lifecycle** (High Priority)
   - Initialization management
   - Basic configuration (KV, policies)
   - Kubernetes auth

2. **Phase 2: Integration** (Medium Priority)
   - Secret population
   - External auth methods (LDAP, OIDC)
   - Backup/restore

3. **Phase 3: Advanced** (Low Priority)
   - PKI management
   - Dynamic credentials
   - Multi-cluster support

## Benefits of Full Operator

1. **Declarative Configuration**: Everything in Git
2. **Automated Lifecycle**: No manual steps
3. **Consistency**: Same config across environments
4. **Recovery**: Automated backup/restore
5. **Integration**: Native K8s patterns

## Example Complete CR

```yaml
apiVersion: vault.banzaicloud.com/v1alpha1
kind: Vault
metadata:
  name: vault
  namespace: vault
spec:
  # Current feature
  unseal:
    transit:
      address: http://192.168.1.42:61200
      keyName: k8s-vault
      mountPath: transit
      tokenSecret: vault-transit-token
  
  # New features
  initialization:
    autoInit: true
    storeRootToken: true
    rootTokenSecret: vault-admin-token
  
  configuration:
    auth:
      kubernetes:
        enabled: true
    secretEngines:
      - path: secret
        type: kv-v2
    policies:
      - name: external-secrets
        fromConfigMap: vault-policies
  
  backup:
    enabled: true
    schedule: "0 2 * * *"
    storage:
      type: s3
      s3:
        bucket: vault-backups
  
  monitoring:
    enabled: true
    serviceMonitor: true
```