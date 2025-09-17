#!/usr/bin/env python3
"""
Convert global-config.yaml to environment variables for Taskfile/Terraform
"""
import yaml
import sys

def yaml_to_env(yaml_file):
    """Convert YAML config to environment variables"""
    with open(yaml_file, 'r') as f:
        config = yaml.safe_load(f)
    
    # Map YAML keys to ARGO_ prefixed env vars
    env_vars = []
    
    # Simple mappings
    mappings = {
        'defaultExternalDomain': 'ARGO_EXTERNAL_DOMAIN',
        'clusterDomain': 'ARGO_CLUSTER_DOMAIN',
        'controlPlaneIP': 'ARGO_CONTROL_PLANE_IP',
        'metallbPool': 'ARGO_METALLB_POOL',
        'haproxyMobileIP': 'ARGO_HAPROXY_MOBILE_IP',
        'harborIP': 'ARGO_HARBOR_IP',
        'harborRegistry': 'ARGO_HARBOR_REGISTRY',
        'harborRegistryTLS': 'ARGO_HARBOR_REGISTRY_TLS',
        'qnapNasIP': 'ARGO_QNAP_NAS_IP',
        'nasVaultAddr': 'ARGO_NAS_VAULT_ADDR',
        'minioQnapUrl': 'ARGO_MINIO_QNAP_URL',
        'minioBrowserRedirectUrl': 'ARGO_MINIO_BROWSER_REDIRECT_URL',
        'minioServerUrl': 'ARGO_MINIO_SERVER_URL',
        'vaultApiAddr': 'ARGO_VAULT_API_ADDR',
        'vaultClusterAddr': 'ARGO_VAULT_CLUSTER_ADDR',
    }
    
    for yaml_key, env_key in mappings.items():
        if yaml_key in config:
            env_vars.append(f'{env_key}={config[yaml_key]}')
    
    # Output as shell export commands
    for var in env_vars:
        print(f'export {var}')

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print("Usage: yaml-to-env.py <path-to-global-config.yaml>")
        sys.exit(1)
    
    yaml_to_env(sys.argv[1])