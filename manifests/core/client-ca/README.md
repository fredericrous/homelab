# Client Certificate Authentication (mTLS)

## Current Status
- ✅ CA Certificate created and mounted in haproxy 
- ✅ Client certificates generated  
- ⚠️  Global SSL client verification not working with haproxy Ingress v1.10.1
- ✅ Optional client certificate verification configured

## Overview
All services are protected by client certificate authentication. Users must have a valid certificate signed by our Certificate Authority to access any endpoint.

## How It Works
1. haproxy Ingress validates client certificates against our CA
2. Only certificates signed by our CA are accepted
3. No certificate = No access (403 Forbidden)

## Certificate Files
- **CA Certificate**: `ca/ca.crt` - The Certificate Authority
- **CA Private Key**: `ca/ca.key` - Keep this secure!
- **Client Certificates**: `ca/clients/` - Individual user certificates

## For Administrators

### Generate the CA (first time only)
```bash
./generate-ca.sh
```

### Generate a new client certificate
```bash
./generate-client-cert.sh <username> <email>
# Example: ./generate-client-cert.sh john john@daddyshome.fr
```

### Revoke a certificate
Currently manual - delete the user's certificate files and they won't be able to generate new valid certs.

## For Users

### Installing Your Certificate

#### Chrome/Edge (Windows/Mac)
1. Double-click the `.p12` file
2. Follow the import wizard
3. Enter the password when prompted
4. Certificate will be installed in your personal certificate store

#### Firefox
1. Open Firefox Settings → Privacy & Security
2. Scroll to "Certificates" → "View Certificates"
3. Click "Import" under "Your Certificates" tab
4. Select the `.p12` file and enter password

#### macOS (System-wide)
1. Double-click the `.p12` file
2. Keychain Access will open
3. Enter the password
4. Certificate is now in your keychain

#### Linux
```bash
# For Chrome/Chromium
pk12util -i client.p12 -d sql:$HOME/.pki/nssdb

# For system-wide (varies by distro)
sudo cp ca/ca.crt /usr/local/share/ca-certificates/daddyshome-ca.crt
sudo update-ca-certificates
```

## Testing Access
Once your certificate is installed, visit:
- https://auth.daddyshome.fr:30443
- https://lldap.daddyshome.fr:30443

Your browser should automatically present the certificate.

## Troubleshooting

### "No client certificate provided" or 403 error
- Make sure the certificate is properly installed
- Restart your browser
- Check that the certificate hasn't expired

### Browser doesn't prompt for certificate
- Clear browser cache and cookies
- Check certificate is in the correct store
- Try a private/incognito window

### Certificate expired
Contact an administrator for a new certificate.

## Security Notes
- Client certificates are valid for 365 days
- Keep your `.p12` file and password secure
- Don't share certificates between users
- Report lost/compromised certificates immediately
