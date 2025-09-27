# Deprecated Scripts

This directory contains scripts that are no longer recommended for use.

## NVIDIA Driver Installation Scripts (Deprecated September 27, 2025)

The following 5 scripts have been replaced by a single unified script `riva-026-update-nvidia-driver-simple.sh`:

### `riva-025-download-nvidia-gpu-drivers.sh`
- **Purpose**: Downloaded NVIDIA drivers to S3 for backup/distribution
- **Issue**: Complex S3 workflow, hardcoded 550.90.12 version
- **Replacement**: Direct repository installation (apt install nvidia-driver-570)

### `riva-030-transfer-drivers-to-gpu-instance.sh`
- **Purpose**: Transferred drivers from S3 to GPU instance
- **Issue**: Requires AWS CLI on GPU instance, complex error handling
- **Replacement**: Direct repository installation eliminates transfer step

### `riva-035-reboot-gpu-instance-after-drivers.sh`
- **Purpose**: Rebooted GPU instance after driver staging
- **Issue**: Manual reboot process, user intervention required
- **Replacement**: Automated reboot and connectivity verification

### `riva-040-install-nvidia-drivers-on-gpu.sh`
- **Purpose**: Actually installed NVIDIA drivers from .run files
- **Issue**: Complex manual installation, hardcoded 550.90.12 version
- **Replacement**: Simple `apt install nvidia-driver-570` approach

### `riva-042-fix-nvidia-driver-mismatch.sh`
- **Purpose**: Fixed version mismatches between kernel modules and libraries
- **Issue**: Complex symlink management after installation
- **Replacement**: Repository installation handles this automatically

### Migration Path for Driver Scripts

Replace any calls to these scripts with:
```bash
./scripts/riva-026-update-nvidia-driver-simple.sh
```

This single script handles:
- Version compatibility checking (570.86+ for RIVA 2.19.0)
- Repository-based driver installation
- Automatic reboot and verification
- Status updates in .env file

### Why These Driver Scripts Were Deprecated

Our manual testing showed that the simple repository approach:
```bash
sudo apt install nvidia-driver-570 -y
sudo reboot
```

Was much more reliable than the complex 5-script chain involving S3 downloads, transfers, and manual .run file installation.

## Other Deprecated Scripts

## riva-080-deployment-s3-microservices.sh
**Status**: Deprecated
**Reason**: Monolithic script with Triton startup issues
**Replacement**: Use modular riva-2xx scripts instead:
- riva-200-bootstrap.sh
- riva-205-system-deps.sh
- riva-210-python-venv.sh
- riva-212-worker-riva-setup.sh
- riva-215-verify-riva-grpc.sh

## riva-080-deploy-traditional-riva-models.sh
**Status**: Deprecated
**Reason**: Replaced by modular riva-2xx workflow
**Replacement**: Use riva-212-worker-riva-setup.sh

## riva-080-save-nim-container-to-s3.sh
**Status**: Deprecated
**Reason**: Specific to NIM containers, superseded by S3-first logic in main scripts
**Replacement**: S3 upload logic is now built into deployment scripts

## riva-070-deploy-websocket-server.sh
**Status**: Deprecated
**Reason**: Hardcoded RIVA version 2.15.0, no S3-first logic
**Replacement**: Use modular riva-2xx scripts with WebSocket integration

## riva-075-download-traditional-riva-models.sh
**Status**: Deprecated
**Reason**: Old download approach without S3-first optimization
**Replacement**: Use riva-212-worker-riva-setup.sh with S3-first caching

## riva-075-validate-models.sh
**Status**: Deprecated
**Reason**: Hardcoded RIVA version 2.15.0, replaced by dynamic validation
**Replacement**: Use riva-215-verify-riva-grpc.sh for validation

## riva-015-deploy-or-restart-aws-gpu-instance.sh
**Status**: Deprecated (Legacy Wrapper)
**Reason**: Monolithic script split into modular components
**Replacement**: Use riva-014-gpu-instance-manager.sh orchestrator
**Files**:
- `riva-015-deploy-or-restart-aws-gpu-instance.sh` - Deprecation wrapper with redirect
- `riva-015-deploy-or-restart-aws-gpu-instance-legacy.sh` - Backup wrapper
- `riva-015-deploy-or-restart-aws-gpu-instance.sh.backup` - Original 590-line script
- `riva-015-deploy-or-restart-aws-gpu-instance.md` - Documentation

**Migration Path**:
```bash
# Old way
./scripts/riva-015-deploy-or-restart-aws-gpu-instance.sh

# New way
./scripts/riva-014-gpu-instance-manager.sh --auto     # Smart mode
./scripts/riva-014-gpu-instance-manager.sh --start    # Start stopped
./scripts/riva-014-gpu-instance-manager.sh --stop     # Stop running
./scripts/riva-014-gpu-instance-manager.sh            # Interactive menu
```

**New Features**:
- JSON structured logging for observability
- Cost tracking and savings calculations
- State persistence across operations
- Comprehensive health checks
- Concurrent operation protection
- Signal handling for graceful interruption

**Date Deprecated**: September 21, 2025

