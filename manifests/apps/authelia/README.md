# Authelia Authentication Setup

## Access URLs

- **Authelia Portal**: http://auth.daddyshome.fr (via haproxy Ingress on port 30080)
- **Direct Access**: http://192.168.1.68:30091 or http://192.168.1.69:30091

## Default Credentials

- **Username**: admin
- **Password**: admin
- **Email**: admin@local

⚠️ **IMPORTANT**: Change the default password immediately after first login!

## Services Configured

1. **HaProxy Ingress Controller**
   - HTTP: Port 30080
   - HTTPS: Port 30443
   - Handles all ingress traffic

2. **Authelia**
   - Authentication and authorization service
   - Connected to PostgreSQL for user storage
   - Connected to Redis for session management
   - Configured for domain: daddyshome.fr

## Database Information

- **Database**: authelia (in PostgreSQL cluster)
- **User**: authelia
- **Password**: authelia-db-password-change-me

## To protect a service with Authelia

Add these annotations to your Ingress:

```yaml
annotations:
  haproxy.ingress.kubernetes.io/auth-url: "http://authelia.authelia.svc.cluster.local/api/verify"
  haproxy.ingress.kubernetes.io/auth-signin: "https://auth.daddyshome.fr"
```

## Next Steps

1. Configure DNS to point *.daddyshome.fr to your cluster nodes
2. Set up SSL certificates (Let's Encrypt recommended)
3. Change default passwords in secrets.yaml
4. Add more users in configmap.yaml
