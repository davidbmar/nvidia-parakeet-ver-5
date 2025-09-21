# RIVA-205-SYSTEM-DEPS: Install OS Dependencies and Log Viewing Tools

## What This Script Does

Installs essential operating system dependencies and specialized log viewing tools needed for the RIVA WebSocket real-time transcription system:

- **Core Dependencies**: curl, wget, jq, unzip, grpc-tools
- **Networking Tools**: netstat, ss, nmap for connectivity testing
- **TLS/SSL Tools**: openssl, certbot for certificate management
- **Log Viewing Tools**: lnav, multitail for enhanced log monitoring
- **Validation Tools**: grpcurl for gRPC endpoint testing

## Preconditions

- Bootstrap script (riva-200) completed successfully
- System has internet connectivity for package downloads
- User has sudo privileges for package installation
- Ubuntu/Debian-based system (script can be adapted for other distros)

## Actions Taken

1. **Update Package Repositories**:
   - `apt update` to refresh package lists
   - Verify apt is working correctly

2. **Install Core System Dependencies**:
   ```bash
   apt install -y curl wget jq unzip git
   apt install -y build-essential ca-certificates
   apt install -y net-tools iputils-ping telnet
   ```

3. **Install Networking and Connectivity Tools**:
   ```bash
   apt install -y netstat-nat ss nmap
   apt install -y dnsutils traceroute
   ```

4. **Install TLS/SSL Management Tools**:
   ```bash
   apt install -y openssl
   apt install -y certbot python3-certbot-nginx  # Optional for Let's Encrypt
   ```

5. **Install gRPC Testing Tools**:
   ```bash
   # Install grpcurl for testing RIVA gRPC endpoints
   GRPCURL_VERSION="1.8.7"
   wget -O grpcurl.tar.gz https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_x86_64.tar.gz
   tar -xzf grpcurl.tar.gz
   sudo mv grpcurl /usr/local/bin/
   rm grpcurl.tar.gz
   ```

6. **Install Enhanced Log Viewing Tools**:
   ```bash
   # lnav - Advanced log file navigator
   apt install -y lnav

   # multitail - Monitor multiple log files simultaneously
   apt install -y multitail
   ```

7. **Install Container Tools** (if needed):
   ```bash
   apt install -y docker.io docker-compose
   systemctl enable docker
   usermod -aG docker $USER
   ```

8. **Validate Installation**:
   - Test each installed tool
   - Verify versions and functionality
   - Create system dependency snapshot

## Outputs/Artifacts

- **System Packages**: All required dependencies installed
- **gRPC Tools**: grpcurl available for RIVA server testing
- **Log Viewers**: lnav and multitail configured and ready
- **Dependency Snapshot**: artifacts/system/dependencies-snapshot.json
- **Installation Log**: Detailed log of all installation steps

## Troubleshooting

**Issue**: Package installation fails
**Solution**: Check internet connectivity and apt sources:
```bash
apt update
apt-cache policy
```

**Issue**: grpcurl download fails
**Solution**: Check GitHub connectivity and version availability:
```bash
curl -I https://github.com/fullstorydev/grpcurl/releases/
```

**Issue**: Docker permission denied
**Solution**: Re-login or restart shell session after docker group addition:
```bash
newgrp docker
# or
sudo su - $USER
```

**Issue**: lnav not displaying logs correctly
**Solution**: Check log file permissions and format:
```bash
lnav --help
lnav -V  # version info
```

## Testing Commands

After installation, test key tools:

```bash
# Test basic tools
jq --version
curl --version
grpcurl --version

# Test log viewers
echo "Test log entry" | lnav
multitail --help

# Test gRPC connectivity (when RIVA server is available)
grpcurl -plaintext $RIVA_HOST:$RIVA_PORT list

# Test TLS tools
openssl version
```

## Next Step

```bash
./scripts/riva-210-python-venv.sh
```

Ready when: All dependencies installed successfully, grpcurl can list gRPC services, and log viewers are functional.