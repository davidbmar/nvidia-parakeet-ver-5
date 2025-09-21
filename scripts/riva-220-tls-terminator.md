# RIVA-220-TLS-TERMINATOR: Setup HTTPS/WSS Termination with TLS Certificates

## What This Script Does

Configures TLS termination for secure WebSocket connections to the RIVA transcription service using Caddy or Nginx reverse proxy:

- **TLS Certificate Management**: Automatic Let's Encrypt or self-signed certificates
- **Reverse Proxy Setup**: Routes HTTPS/WSS traffic to backend WebSocket service
- **Security Configuration**: SSL/TLS protocols, ciphers, and security headers
- **Certificate Renewal**: Automated certificate renewal setup
- **Health Monitoring**: TLS endpoint testing and validation
- **Firewall Configuration**: Proper port access rules

## Preconditions

- gRPC verification (riva-215) completed successfully
- Domain name configured in TLS_DOMAIN environment variable
- DNS resolution for domain (for Let's Encrypt certificates)
- Sudo privileges for system configuration
- Internet connectivity for package installation and certificate requests

## Actions Taken

1. **TLS Configuration Validation**:
   ```bash
   # Validate domain format and resolution
   nslookup $TLS_DOMAIN
   echo $TLS_DOMAIN | grep -E '^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$'
   ```

2. **TLS Terminator Installation** (Auto-selects best option):
   ```bash
   # Option A: Caddy (recommended)
   curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
   sudo apt install caddy

   # Option B: Nginx with Certbot
   sudo apt install nginx certbot python3-certbot-nginx
   ```

3. **Certificate Setup** (Multiple modes supported):
   ```bash
   # Auto/Let's Encrypt (production)
   certbot --nginx -d $TLS_DOMAIN --non-interactive --agree-tos

   # Self-signed (development)
   openssl req -x509 -newkey rsa:4096 -keyout domain.key -out domain.crt -days 365 -nodes
   ```

4. **Reverse Proxy Configuration**:

   **Caddy Configuration** (`/etc/caddy/Caddyfile`):
   ```caddyfile
   your.domain.com {
       handle /ws* {
           reverse_proxy localhost:8443
       }
       handle /* {
           root * /path/to/www
           file_server
       }
   }
   ```

   **Nginx Configuration** (`/etc/nginx/sites-available/domain.com`):
   ```nginx
   server {
       listen 443 ssl http2;
       server_name your.domain.com;

       location /ws {
           proxy_pass http://localhost:8443;
           proxy_http_version 1.1;
           proxy_set_header Upgrade $http_upgrade;
           proxy_set_header Connection "upgrade";
       }
   }
   ```

5. **Certificate Renewal Setup**:
   ```bash
   # Caddy: Automatic renewal built-in

   # Nginx: Certbot timer
   sudo systemctl enable certbot.timer
   sudo certbot renew --dry-run
   ```

6. **Firewall Configuration**:
   ```bash
   sudo ufw allow 80/tcp   # HTTP (redirects)
   sudo ufw allow 443/tcp  # HTTPS/WSS
   sudo ufw allow 22/tcp   # SSH access
   ```

7. **TLS Endpoint Testing**:
   ```bash
   curl -k https://$TLS_DOMAIN/health
   openssl s_client -connect $TLS_DOMAIN:443 -servername $TLS_DOMAIN
   ```

## Environment Variables

Required variables in `.env`:
```bash
# TLS Configuration
TLS_DOMAIN=your.domain.com
TLS_TERMINATOR=caddy          # caddy, nginx, or auto
TLS_CERT_MODE=auto            # auto, letsencrypt, self-signed, manual
TLS_EMAIL=admin@domain.com    # For Let's Encrypt

# WebSocket Backend
WS_PORT=8443                  # Backend WebSocket service port
USE_TLS=true                  # Enable TLS termination

# Optional: Manual certificates
TLS_CERT_FILE=/path/to/cert.pem
TLS_KEY_FILE=/path/to/key.pem
```

## Outputs/Artifacts

- **TLS Configuration Report**: `artifacts/checks/tls-config-TIMESTAMP.json`
- **Proxy Configuration**:
  - Caddy: `/etc/caddy/Caddyfile`
  - Nginx: `/etc/nginx/sites-available/$TLS_DOMAIN`
- **Certificates**:
  - Let's Encrypt: `/etc/letsencrypt/live/$TLS_DOMAIN/`
  - Self-signed: `./certs/$TLS_DOMAIN.{crt,key}`
- **Service Status**: TLS terminator service status and health

## TLS Certificate Modes

### 1. Auto/Let's Encrypt (Production)
```bash
TLS_CERT_MODE=auto
TLS_DOMAIN=yourdomain.com
TLS_EMAIL=admin@yourdomain.com
```
- Automatic certificate issuance from Let's Encrypt
- Automatic renewal every 60 days
- Domain must resolve to server IP
- Requires internet connectivity

### 2. Self-Signed (Development)
```bash
TLS_CERT_MODE=self-signed
TLS_DOMAIN=localhost
```
- Generated locally with OpenSSL
- No external dependencies
- Browser security warnings expected
- Suitable for development/testing

### 3. Manual Certificates
```bash
TLS_CERT_MODE=manual
TLS_CERT_FILE=/path/to/certificate.pem
TLS_KEY_FILE=/path/to/private.key
```
- Use existing certificates
- Corporate or custom CA certificates
- Manual renewal required

## Troubleshooting

**Issue**: Domain does not resolve
**Solution**:
```bash
# Check DNS resolution
nslookup $TLS_DOMAIN
dig $TLS_DOMAIN A

# For development, use self-signed mode
export TLS_CERT_MODE=self-signed
```

**Issue**: Let's Encrypt certificate fails
**Solution**:
```bash
# Check domain accessibility
curl -I http://$TLS_DOMAIN/.well-known/acme-challenge/test

# Check Certbot logs
sudo tail -f /var/log/letsencrypt/letsencrypt.log

# Fallback to self-signed
export TLS_CERT_MODE=self-signed
```

**Issue**: Caddy/Nginx service fails to start
**Solution**:
```bash
# Check configuration syntax
sudo caddy validate --config /etc/caddy/Caddyfile
sudo nginx -t

# Check service logs
sudo journalctl -u caddy -f
sudo journalctl -u nginx -f

# Check port conflicts
sudo netstat -tlnp | grep -E ':(80|443) '
```

**Issue**: WebSocket connection fails through proxy
**Solution**:
```bash
# Test backend service directly
curl http://localhost:$WS_PORT/health

# Check proxy configuration
grep -A 10 "proxy_pass\|reverse_proxy" /etc/*/*/config

# Test with verbose curl
curl -v -H "Upgrade: websocket" -H "Connection: upgrade" https://$TLS_DOMAIN/ws
```

**Issue**: Certificate renewal fails
**Solution**:
```bash
# Test renewal manually
sudo certbot renew --dry-run --verbose

# Check renewal timer
sudo systemctl status certbot.timer

# Check certificate expiry
openssl x509 -in /etc/letsencrypt/live/$TLS_DOMAIN/cert.pem -noout -dates
```

## Security Considerations

1. **TLS Protocol Version**: Only TLS 1.2+ enabled
2. **Cipher Suites**: Strong ciphers only, no weak algorithms
3. **Certificate Validation**: Proper certificate chain validation
4. **HSTS Headers**: HTTP Strict Transport Security enabled
5. **Secure Headers**: CSP, X-Frame-Options, etc.
6. **Rate Limiting**: Protection against DoS attacks
7. **Access Logs**: Comprehensive logging for security monitoring

## Testing Commands

Manual verification commands for troubleshooting:

```bash
# Test HTTPS endpoint
curl -k https://$TLS_DOMAIN/health

# Test HTTP redirect
curl -I http://$TLS_DOMAIN/health

# Test TLS certificate
openssl s_client -connect $TLS_DOMAIN:443 -servername $TLS_DOMAIN

# Test WebSocket upgrade
curl -v -H "Upgrade: websocket" -H "Connection: upgrade" https://$TLS_DOMAIN/ws

# Check certificate expiry
echo | openssl s_client -connect $TLS_DOMAIN:443 2>/dev/null | openssl x509 -noout -dates

# Test cipher strength
nmap --script ssl-enum-ciphers -p 443 $TLS_DOMAIN

# Check HSTS headers
curl -I https://$TLS_DOMAIN | grep -i strict-transport-security
```

## Performance and Monitoring

```bash
# Monitor TLS handshake performance
time openssl s_client -connect $TLS_DOMAIN:443 </dev/null

# Check concurrent connection limits
ab -n 1000 -c 50 https://$TLS_DOMAIN/health

# Monitor certificate renewal
sudo certbot certificates

# Check proxy performance
curl -w "@curl-format.txt" https://$TLS_DOMAIN/health
```

## Expected Results

**Successful TLS Setup Shows**:
- ✅ TLS terminator (Caddy/Nginx) installed and running
- ✅ Valid TLS certificate (Let's Encrypt or self-signed)
- ✅ HTTPS endpoint responding with 200 status
- ✅ HTTP traffic redirecting to HTTPS
- ✅ WebSocket upgrade support configured
- ✅ Certificate renewal automation active
- ✅ Firewall rules properly configured

## Next Step

```bash
./scripts/riva-225-bridge-config.sh
```

Ready when: TLS termination is active, certificates are valid, and HTTPS endpoint responds successfully with WebSocket upgrade support.