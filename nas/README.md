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
3-Tier Backup Strategy:
┌─────────────────┐     ┌──────────────────┐     ┌──────────────────┐     ┌─────────────┐
│ Kubernetes      │     │ Kubernetes       │     │ QNAP MinIO       │     │ AWS S3      │
│ Velero          │────▶│ MinIO            │────▶│ (Long-term)      │────▶│ (Archive)   │
└─────────────────┘     └──────────────────┘     └──────────────────┘     └─────────────┘
                        Immediate backups       Sync >2 days old         Weekly sync
                                                    (daily)              (Sundays)

Vault Architecture:
┌─────────────────┐     ┌──────────────────┐
│ Kubernetes      │◀────│ QNAP Vault       │
│ Vault (Unsealed)│     │ (Transit Keys +  │
└─────────────────┘     │  AWS Credentials)│
                        └──────────────────┘
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

1. **Immediate**: Velero backs up to Kubernetes MinIO (fast, local)
2. **Daily**: Kubernetes MinIO syncs files >2 days old to QNAP MinIO
3. **Weekly**: QNAP MinIO syncs to AWS S3 (keeps only 7 most recent backups)

## Benefits

- **High Availability**: QNAP Vault is always available for unsealing
- **Tiered Storage**: Recent backups are fast, older ones archived
- **Cost Efficient**: Only long-term backups go to S3
- **AWS Credentials**: Stored securely in QNAP Vault, not K8s