# HAProxy Ingress Controller

This directory contains the HAProxy ingress controller configuration for the homelab cluster.

## Architecture

The cluster uses a subdomain-based architecture where each application is accessible at `<app>.daddyshome.fr`:
- `argocd.daddyshome.fr` - ArgoCD UI
- `drive.daddyshome.fr` - Nextcloud (with mTLS)
- `drive-mobile.daddyshome.fr` - Nextcloud mobile access (without mTLS)
- `vault.daddyshome.fr` - Vault UI
- etc.

## Global Configuration

The following settings are configured globally in the ConfigMap to support this architecture:

### 1. **Strict SNI** (`strict-sni: "true"`)
- Ensures HAProxy matches the correct certificate based on the SNI hostname
- Without this, HAProxy might serve the wrong certificate (e.g., ArgoCD cert for Nextcloud)
- Essential for proper SSL/TLS termination in multi-domain setups

### 2. **Default SSL Certificate** (`ssl-certificate: "haproxy-controller/haproxy-default-ssl-tls"`)
- Wildcard certificate for `*.daddyshome.fr`
- Acts as a fallback when specific certificates are missing
- Prevents certificate errors during initial deployment

### 3. **Client CA** (`client-ca: "haproxy-controller/client-ca-cert"`)
- Enables mTLS (mutual TLS) authentication
- Clients must present a valid certificate signed by this CA
- Used for enhanced security on sensitive applications

## mTLS Configuration

Some applications use mTLS for additional security:
- Desktop/browser access requires client certificates
- Mobile endpoints (e.g., `drive-mobile.daddyshome.fr`) bypass mTLS for compatibility

## Certificate Management

1. **Application-specific certificates**: Each app can have its own certificate via cert-manager
2. **Default wildcard certificate**: Covers all subdomains as a fallback
3. **Client certificates**: Generated and stored in Vault for mTLS authentication

## Files

- `haproxy-ingress.yaml` - Main HAProxy deployment and configuration
- `ingressclass.yaml` - Defines the `haproxy` ingress class
- `default-ssl-certificate.yaml` - Wildcard certificate for `*.daddyshome.fr`
- `client-ca-externalsecret.yaml` - Syncs client CA from Vault
- `vault-configure-haproxy.yaml` - Post-deployment Vault configuration