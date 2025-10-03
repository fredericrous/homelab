# Plex Media Server

## Prerequisites

### Plex Claim Token

The Plex claim token is configured via the `.env` file:

1. Get a claim token from https://www.plex.tv/claim/ (valid for 4 minutes)
2. Add it to your `.env` file:
   ```
   PLEX_CLAIM_TOKEN=claim-XXXXXXXXXXXXXXXXXXXX
   ```
3. Run `task bootstrap` to update the cluster-vars secret

The token is automatically reflected to the plex namespace and used to link your Plex server to your Plex account on first startup.

## Configuration

The Plex configuration is stored in Vault at `secret/plex/config` and includes:
- `timezone`: Server timezone (default: Europe/Paris)
- `claim`: Your Plex claim token

## GPU Support

This deployment is configured to use NVIDIA GPU for hardware transcoding. The deployment:
- Uses the `nvidia` RuntimeClass
- Runs in privileged mode (required for GPU access)
- Requests 1 GPU resource

## Storage

- **Config**: 50Gi PVC for Plex configuration and metadata
- **Media**: NFS mount to your media storage

## Access

Plex is accessible at:
- https://plex.daddyshome.fr (requires mTLS client certificate)
- Direct access on port 32400 for Plex clients