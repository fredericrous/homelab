# Homelab Values

This **PRIVATE** repository contains environment-specific values for the homelab deployment.

## Structure

- `.env` - Environment variables for your homelab (auto-synced)

## Security

⚠️ **KEEP THIS REPOSITORY PRIVATE** ⚠️

This repository contains:
- IP addresses
- Domain names  
- Configuration values

While not passwords, these values should not be public.

## Usage

This repository is automatically managed by the main homelab repository.

To update values:
1. Edit `.env` in the main homelab repository
2. Run `task sync-env` to push changes here

## What Goes Here

- ✅ `ARGO_*` prefixed variables (for ArgoCD manifest templating)
- ✅ Repository URLs (like `HOMELAB_VALUES_REPO`)
- ✅ Non-sensitive configuration values
- ❌ Passwords (use Vault)
- ❌ API keys (use Vault)
- ❌ Certificates (use cert-manager)

## Backup

Remember to backup this repository as it contains your environment configuration.