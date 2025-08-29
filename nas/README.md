# NAS Services (QNAP Docker Swarm)

This directory contains Docker Compose configurations for services running on QNAP NAS via Docker Swarm.

## Services

### Vault (Primary)
- **Purpose**: Main Vault instance that provides transit unsealing for Kubernetes Vault
- **Port**: 8200
- **Data**: `/VMs/vault`
- **Role**: Stores transit keys for auto-unsealing Kubernetes Vault

### MinIO
- **Purpose**: S3-compatible object storage for Velero backups
- **Ports**: 9000 (API), 9001 (Console)
- **Data**: `/VMs/minio/data`
- **Role**: Primary backup destination with replication to AWS S3

## Architecture

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────┐
│ Kubernetes      │     │ QNAP MinIO       │     │ AWS S3      │
│ Velero Backups  │────▶│ (Primary Store)  │────▶│ (Replica)   │
└─────────────────┘     └──────────────────┘     └─────────────┘

┌─────────────────┐     ┌──────────────────┐
│ Kubernetes      │◀────│ QNAP Vault       │
│ Vault (Unsealed)│     │ (Transit Keys)   │
└─────────────────┘     └──────────────────┘
```

## Deployment

1. **Deploy services**:
   ```bash
   ./deploy.sh
   ```

2. **Initialize Vault**:
   ```bash
   cd vault
   ./init-vault.sh
   # Save the output tokens!
   ```

3. **Setup MinIO replication**:
   ```bash
   cd minio
   export AWS_ACCESS_KEY_ID=your-key
   export AWS_SECRET_ACCESS_KEY=your-secret
   ./setup-replication.sh
   ```

## Docker TLS Connection

The `cert/` directory should contain Docker TLS certificates:
- `ca.pem`
- `cert.pem`
- `key.pem`

Connection uses: `DOCKER_HOST=192.168.1.42:2376`

## Backup Flow

1. Velero in Kubernetes backs up to QNAP MinIO
2. QNAP MinIO replicates to AWS S3 automatically
3. Single backup configuration in Kubernetes (simpler!)

## Benefits

- **High Availability**: QNAP Vault is always available for unsealing
- **Simplified Backups**: One backup job instead of two
- **Automatic Replication**: MinIO handles S3 sync
- **Centralized Storage**: All persistent data on QNAP