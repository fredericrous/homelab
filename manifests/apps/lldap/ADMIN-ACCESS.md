# LLDAP Admin Access

## Retrieving Admin Credentials

The LLDAP admin credentials are automatically generated during initial setup and stored in Vault.

### Using kubectl and Vault CLI

```bash
# Port-forward to Vault
kubectl port-forward -n vault svc/vault 8200:8200

# Set environment
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$(kubectl get secret vault-admin-token -n vault -o jsonpath='{.data.token}' | base64 -d)

# Get admin credentials
vault kv get secret/lldap/admin-credentials
```

### Direct kubectl Command

```bash
# Get admin username
kubectl exec -n vault vault-0 -- vault kv get -field=username secret/lldap/admin-credentials

# Get admin password
kubectl exec -n vault vault-0 -- vault kv get -field=password secret/lldap/admin-credentials
```

## Admin Access Details

- **Web UI URL**: https://lldap.daddyshome.fr
- **Admin Username**: admin (NOT admin@daddyshome.fr - that's the email)
- **Admin Password**: Retrieved from Vault as shown above

Note: The admin email is set to admin@daddyshome.fr but the login username is just "admin".

## LDAP Admin Access

For applications that need LDAP admin access:
- **Admin DN**: cn=admin,dc=daddyshome,dc=fr
- **Admin Password**: Retrieved from Vault field `ldap-admin-password`

## Creating an ExternalSecret for Admin Credentials

If you need the admin credentials in another namespace, create an ExternalSecret:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: lldap-admin-credentials
  namespace: your-namespace
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: lldap-admin-credentials
  data:
  - secretKey: username
    remoteRef:
      key: secret/data/lldap/admin-credentials
      property: username
  - secretKey: password
    remoteRef:
      key: secret/data/lldap/admin-credentials
      property: password
```