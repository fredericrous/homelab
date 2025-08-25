# LLDAP (Light LDAP) Setup

## Access URLs

- **LLDAP Admin Panel**: http://lldap.daddyshome.fr (via NGINX Ingress on port 30080)
- **Direct Access**: http://192.168.1.68:30080/lldap

## Default Credentials

- **Username**: admin
- **Password**: lldap-admin-password

⚠️ **IMPORTANT**: Change the default password immediately after first login!

## Configuration

LLDAP is configured with:
- PostgreSQL backend for data storage
- Base DN: `dc=daddyshome,dc=fr`
- LDAP port: 3890
- HTTP port: 17170

## Integration with Authelia

Authelia is configured to use LLDAP as its authentication backend:
- LDAP URL: `ldap://lldap.lldap.svc.cluster.local:3890`
- Admin bind DN: `uid=admin,ou=people,dc=daddyshome,dc=fr`

## Managing Users

1. Access the LLDAP admin panel at http://lldap.daddyshome.fr
2. Login with admin credentials
3. Create users and groups as needed
4. Users created in LLDAP will be able to authenticate through Authelia

## Database

- **Database**: lldap (in PostgreSQL cluster)
- **User**: lldap
- **Password**: lldap-db-password-change-me

## Testing Authentication

1. Visit any protected service (*.daddyshome.fr)
2. You'll be redirected to Authelia login page
3. Login with LLDAP credentials
4. Complete 2FA setup if required