# Vault Transit Unseal Operator - Reflector Support

To add Reflector support to the vault-transit-unseal-operator, update the `secretManager.CreateOrUpdate` method in `controllers/vaulttransitunseal_controller.go`:

```go
func (s *secretManager) CreateOrUpdate(ctx context.Context, namespace, name string, data map[string][]byte) error {
	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: namespace,
		},
	}

	op, err := controllerutil.CreateOrUpdate(ctx, s.client, secret, func() error {
		// Add Reflector annotations for vault-admin-token
		if name == "vault-admin-token" && namespace == "vault" {
			if secret.Annotations == nil {
				secret.Annotations = make(map[string]string)
			}
			secret.Annotations["reflector.v1.k8s.emberstack.com/reflection-allowed"] = "true"
			secret.Annotations["reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces"] = "external-secrets,postgres,haproxy-controller,authelia,lldap,harbor,nextcloud,stremio,argocd,plex,argo"
			secret.Annotations["reflector.v1.k8s.emberstack.com/reflection-auto-enabled"] = "true"
		}
		
		secret.Data = data
		return nil
	})

	if err != nil {
		s.log.Error(err, "Failed to create or update secret", "namespace", namespace, "name", name)
		return err
	}

	s.log.V(1).Info("Secret operation completed", "operation", op, "namespace", namespace, "name", name)
	return nil
}
```

This change will automatically add Reflector annotations when the operator creates the `vault-admin-token` secret during Vault initialization.