# Policy for cert-manager to read its secrets from Vault
path "secret/data/ovh-dns" {
  capabilities = ["read"]
}

path "secret/data/cert-manager/*" {
  capabilities = ["read"]
}

# Allow listing to verify access
path "secret/metadata/cert-manager/*" {
  capabilities = ["list"]
}