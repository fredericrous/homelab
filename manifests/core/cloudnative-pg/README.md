# CloudNativePG for Homelab

Minimal CloudNativePG setup for running PostgreSQL clusters in Kubernetes.

## Components

- **CloudNativePG Operator**: v1.24.1
- **PostgreSQL**: 16.6 with 3 instances for HA
- **Storage**: Uses Rook Ceph block storage (10Gi per instance)
- **Resources**: 512Mi-1Gi memory, 250m-1000m CPU per instance

## Files

- `kustomization.yaml`: Main Kustomize configuration
- `postgres-cluster.yaml`: PostgreSQL cluster definition
- `postgres-secrets.yaml`: Database credentials (**UPDATE BEFORE DEPLOYING**)
- `postgres-services.yaml`: Services for application connections

## Pre-deployment Steps

1. **Update passwords** in `postgres-secrets.yaml`:
   ```bash
   # Generate new passwords
   openssl rand -base64 16
   ```

2. **Deploy**:
   ```bash
   kubectl apply -k .
   ```

## Connecting Applications

Applications like Nextcloud can connect using:

- **Host**: `postgres-apps-rw.postgres.svc.cluster.local`
- **Port**: `5432`
- **Database**: Create as needed
- **Username**: `appuser` (from postgres-app-user secret)
- **Password**: From postgres-app-user secret

### Service Endpoints

- `postgres-apps-rw`: Primary (read-write)
- `postgres-apps-ro`: Replicas (read-only)
- `postgres-apps-any`: Any instance (load balanced)

## Creating Application Databases

```bash
# Connect to primary instance
kubectl -n postgres exec -it postgres-apps-1 -- psql -U postgres

# Create database for Nextcloud
CREATE DATABASE nextcloud;
GRANT ALL PRIVILEGES ON DATABASE nextcloud TO appuser;
```

## Monitoring

Check cluster status:
```bash
kubectl -n postgres get cluster
kubectl -n postgres get pods
```

## Backup/Restore

CloudNativePG supports backup to S3-compatible storage. Configure as needed for production use.