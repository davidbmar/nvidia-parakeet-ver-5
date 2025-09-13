#!/bin/bash

# Generate self-signed SSL certificate for HTTPS server
# This is for development/testing only - use proper certificates in production

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}🔒 Generating SSL Certificate for HTTPS Server${NC}"
echo "================================================================"

# Get server IP from .env or use defaults
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    SERVER_IP="${GPU_INSTANCE_IP:-localhost}"
else
    SERVER_IP="localhost"
fi

# Certificate paths
CERT_DIR="/opt/rnnt"
CERT_PATH="$CERT_DIR/server.crt"
KEY_PATH="$CERT_DIR/server.key"

# Check if running with sudo or if we can write to /opt/rnnt
if [ -w "/opt" ]; then
    echo "Using /opt/rnnt for certificates"
else
    # Fallback to local directory
    CERT_DIR="$PROJECT_ROOT/certs"
    CERT_PATH="$CERT_DIR/server.crt"
    KEY_PATH="$CERT_DIR/server.key"
    echo -e "${YELLOW}⚠️  Cannot write to /opt/rnnt, using $CERT_DIR instead${NC}"
fi

# Create certificate directory
mkdir -p "$CERT_DIR"

# Check if certificates already exist
if [ -f "$CERT_PATH" ] && [ -f "$KEY_PATH" ]; then
    echo -e "${YELLOW}⚠️  SSL certificates already exist:${NC}"
    echo "   Certificate: $CERT_PATH"
    echo "   Key: $KEY_PATH"
    
    read -p "Do you want to regenerate them? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Keeping existing certificates"
        exit 0
    fi
    
    echo "Backing up existing certificates..."
    mv "$CERT_PATH" "$CERT_PATH.bak"
    mv "$KEY_PATH" "$KEY_PATH.bak"
fi

# Generate self-signed certificate
echo -e "${BLUE}Generating self-signed certificate...${NC}"

# Create OpenSSL config for certificate with SAN
cat > /tmp/openssl.cnf << EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req

[dn]
C=US
ST=State
L=City
O=RNN-T Server
OU=Development
CN=$SERVER_IP

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = *.localhost
IP.1 = 127.0.0.1
IP.2 = $SERVER_IP
EOF

# Generate private key and certificate
openssl req -x509 \
    -nodes \
    -days 365 \
    -newkey rsa:2048 \
    -keyout "$KEY_PATH" \
    -out "$CERT_PATH" \
    -config /tmp/openssl.cnf \
    -extensions v3_req

# Set appropriate permissions
chmod 600 "$KEY_PATH"
chmod 644 "$CERT_PATH"

# Clean up
rm -f /tmp/openssl.cnf

echo -e "${GREEN}✅ SSL certificates generated successfully!${NC}"
echo "================================================================"
echo "Certificate: $CERT_PATH"
echo "Private Key: $KEY_PATH"
echo "Valid for: 365 days"
echo ""
echo -e "${YELLOW}📝 Note: This is a self-signed certificate.${NC}"
echo "   Browsers will show a security warning."
echo "   For production, use a certificate from a trusted CA."
echo ""

# Update HTTPS server configuration if needed
if [ "$CERT_DIR" != "/opt/rnnt" ]; then
    echo -e "${YELLOW}⚠️  Certificates are not in the default location.${NC}"
    echo "   Update rnnt-https-server.py to use:"
    echo "   - Certificate: $CERT_PATH"
    echo "   - Key: $KEY_PATH"
fi

echo -e "${GREEN}🚀 Ready to start HTTPS server!${NC}"