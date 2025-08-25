# Simple Job Template Design

## Why This is the Simplest Approach

The v2 template approach is simple because:

1. **One script for all services** - The logic is in the base template
2. **Services only provide values** - Just 5-6 environment variables
3. **No hidden complexity** - It's just environment variable substitution
4. **Easy to test** - You can run the script manually with env vars

## How Services Use It

```yaml
# In service's kustomization.yaml
resources:
  - ../base/job-templates/job-vault-configure-v2.yaml

patches:
  - target:
      kind: Job
      name: vault-configure
    patch: |-
      apiVersion: batch/v1
      kind: Job
      metadata:
        name: vault-configure-myservice
      spec:
        template:
          spec:
            containers:
            - name: vault-configure
              env:
              - name: SERVICE_NAME
                value: myservice
              - name: POLICY_NAME
                value: myservice
              - name: ROLE_NAME
                value: myservice
              - name: SERVICE_ACCOUNT
                value: myservice
              - name: NAMESPACE
                value: myservice
              - name: POLICY_CONTENT
                value: |
                  path "secret/data/myservice/*" {
                    capabilities = ["read"]
                  }
```

## Benefits

1. **DRY** - No script duplication
2. **Maintainable** - Fix bugs in one place
3. **Readable** - Clear what each service configures
4. **Testable** - Can validate policies easily
5. **GitOps** - Everything in version control

## Migration Effort

- Small: Update each service's kustomization.yaml
- Remove old job files
- Test each service

This is simpler than ConfigMaps or complex Kustomize features while still achieving the goal of reducing duplication.