# QNAP Vault Setup for Transit Auto-Unseal

## Prerequisites on QNAP

1. Install and initialize Vault on QNAP via Docker Compose
2. Unseal the QNAP Vault

## Setup Transit Engine on QNAP Vault

Run these commands on your QNAP Vault:

```bash
# Enable transit engine
vault secrets enable transit

# Create the autounseal key
vault write -f transit/keys/autounseal

# Create policy for Kubernetes Vault
vault policy write autounseal - <<EOF
path "transit/encrypt/autounseal" {
   capabilities = [ "update" ]
}

path "transit/decrypt/autounseal" {
   capabilities = [ "update" ]
}
EOF

# Create token for Kubernetes Vault
vault token create -policy="autounseal" -ttl=768h
# Save the token value!
```

## Configure Kubernetes Vault

1. Update the QNAP Vault IP in `vault-config.yaml`:
   ```yaml
   seal "transit" {
     address = "http://YOUR_QNAP_IP:8200"
   ```

2. Create the token secret:
   ```bash
   kubectl create secret generic vault-transit-token \
     --namespace=vault \
     --from-literal=token='YOUR_TOKEN_FROM_ABOVE'
   ```

3. Deploy Vault - it will auto-unseal using the QNAP Vault!

## Benefits

- Kubernetes Vault auto-unseals on restart
- No more initialization detection issues  
- QNAP Vault acts as the secure key holder
- Clean separation of concerns