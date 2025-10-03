lldap-admin-password
VAULT_TOKEN=$(kubectl get secret vault-admin-token -n vault -o jsonpath='{.data.token}' | base64 -d)



## access vault secrets

// kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1)

export KUBECONFIG=/Users/fredericrous/.kube/config && kubectl port-forward -n vault svc/vault 8200:8200
export KUBECONFIG=/Users/fredericrous/.kube/config && kubectl exec -n vault vault-0 -- vault operator unseal $(kubectl get secret vault-keys -n vault -o jsonpath='{.data.unseal-key}' | base64 -d)
export VAULT_ADDR=http://127.0.0.1:8200 && export VAULT_TOKEN=$(kubectl get secret vault-admin-token -n vault -o jsonpath='{.data.token}' | base64 -d) && vault kv list secret/

## access kubernetes secrets

kubectl get secret smbcreds  -o jsonpath='{.data}' | jq 'map_values(@base64d)
