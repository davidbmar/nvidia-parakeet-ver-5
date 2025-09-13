# NVIDIA Parakeet Riva ASR - Script Organization Guide

## Overview
Scripts are organized with **5-number spacing** to allow easy insertion of new functionality. Each script has a **descriptive name** that clearly indicates its purpose.

## Script Categories and Numbering

### 005-010: Project Setup and Master Scripts
- `riva-005-setup-project-configuration.sh` - Interactive project configuration setup
- `riva-010-run-complete-deployment-pipeline.sh` - Master script to run complete deployment

### 015-040: Infrastructure and Environment Setup
- `riva-015-deploy-or-restart-aws-gpu-instance.sh` - Deploy new or restart existing AWS GPU instance
- `riva-020-configure-aws-security-groups.sh` - Configure security groups and network access
- `riva-025-download-nvidia-gpu-drivers.sh` - Download NVIDIA GPU drivers
- `riva-030-transfer-drivers-to-gpu-instance.sh` - Transfer drivers to GPU instance
- `riva-035-reboot-gpu-instance-after-drivers.sh` - Reboot instance after driver installation
- `riva-040-install-nvidia-drivers-on-gpu.sh` - Install NVIDIA drivers on GPU instance

### 045-065: Environment Preparation and NIM Containers
- `riva-045-prepare-riva-environment.sh` - Prepare Riva runtime environment
- `riva-050-fix-gpu-docker-access.sh` - Fix GPU access for Docker containers

#### NIM Container Path (CHOICE POINT)
Choose one of these paths:

**Path A: Download Fresh NIM Container**
- `riva-055-download-nim-container-from-nvidia.sh` - Download NIM container fresh from NVIDIA

**Path B: Restore from S3 Backup** 
- `riva-055-restore-nim-container-from-s3-backup.sh` - Restore NIM container from S3 backup

**Deployment and Backup**
- `riva-060-deploy-nim-container-for-asr.sh` - Deploy NIM container for ASR service
- `riva-065-backup-nim-container-to-s3.sh` - Backup NIM container to S3 for future use

### 070-085: Traditional Riva Server (Legacy Path)
- `riva-070-setup-traditional-riva-server.sh` - Setup traditional Riva server
- `riva-075-download-traditional-riva-models.sh` - Download traditional Riva models
- `riva-080-deploy-traditional-riva-models.sh` - Deploy traditional Riva models
- `riva-085-start-traditional-riva-server.sh` - Start traditional Riva server

### 090-095: Application Deployment
- `riva-090-deploy-websocket-asr-application.sh` - Deploy WebSocket ASR application
- `riva-095-deploy-static-web-files.sh` - Deploy static web files

### 100-125: Testing and Validation
- `riva-100-test-basic-integration.sh` - Basic integration testing
- `riva-105-test-riva-server-connectivity.sh` - Test Riva server connectivity
- `riva-110-test-audio-file-transcription.sh` - Test audio file transcription
- `riva-115-test-realtime-streaming-transcription.sh` - Test real-time streaming
- `riva-120-test-complete-end-to-end-pipeline.sh` - Complete end-to-end testing
- `riva-125-enable-production-riva-mode.sh` - Enable production mode

### 999: Cleanup
- `riva-999-destroy-all-resources.sh` - Destroy all deployed resources

## Deployment Paths

### Modern NIM-Based Deployment (Recommended)
```bash
# Setup
./scripts/riva-005-setup-project-configuration.sh
./scripts/riva-015-deploy-or-restart-aws-gpu-instance.sh
./scripts/riva-020-configure-aws-security-groups.sh

# NIM Container (choose one)
./scripts/riva-055-download-nim-container-from-nvidia.sh        # OR
./scripts/riva-055-restore-nim-container-from-s3-backup.sh     # Alternative

# Deploy and Test  
./scripts/riva-060-deploy-nim-container-for-asr.sh
./scripts/riva-090-deploy-websocket-asr-application.sh
./scripts/riva-100-test-basic-integration.sh

# Backup for future use
./scripts/riva-065-backup-nim-container-to-s3.sh
```

### Traditional Riva Deployment (Legacy)
```bash
# Setup (same)
./scripts/riva-005-setup-project-configuration.sh  
./scripts/riva-015-deploy-or-restart-aws-gpu-instance.sh
./scripts/riva-020-configure-aws-security-groups.sh

# Traditional Riva Path
./scripts/riva-070-setup-traditional-riva-server.sh
./scripts/riva-075-download-traditional-riva-models.sh
./scripts/riva-080-deploy-traditional-riva-models.sh
./scripts/riva-085-start-traditional-riva-server.sh

# Application and Testing (same)
./scripts/riva-090-deploy-websocket-asr-application.sh
./scripts/riva-100-test-basic-integration.sh
```

## Key Features

### Logging Integration
All scripts use the common logging framework (`riva-common-functions.sh`) that provides:
- Structured logging with timestamps
- Progress tracking and status updates  
- Error handling and recovery suggestions
- Log file management in `logs/` directory

### Naming Convention
- **Format**: `riva-XXX-verb-descriptive-noun.sh`
- **Examples**: 
  - `riva-055-download-nim-container-from-nvidia.sh`
  - `riva-090-deploy-websocket-asr-application.sh`
  - `riva-120-test-complete-end-to-end-pipeline.sh`

### Choice Points
The system provides clear **choice points** where users can select different paths:
- **055**: Download fresh vs. restore from backup
- **070-085**: Traditional Riva vs. NIM containers
- **Testing**: Granular testing options (105, 110, 115, 120)

### 5-Number Spacing Benefits
- **Easy insertion**: Add new scripts between existing ones
- **Clear organization**: Related functionality grouped together  
- **Future-proof**: Room for expansion without renumbering
- **Visual clarity**: Easy to see script relationships

## Adding New Scripts

When adding new scripts:
1. **Choose appropriate number range** based on functionality
2. **Use descriptive naming** following the established pattern  
3. **Integrate logging** using `riva-common-functions.sh`
4. **Update this guide** and relevant documentation
5. **Test integration** with existing scripts

## Migration Notes

This organization replaces the old numbering system where scripts were numbered too closely together. Key changes:
- Removed duplicate functionality (multiple 046, 047 scripts)
- Clear separation between NIM and traditional Riva paths
- Better organization by functional area
- Consistent naming that describes purpose
- 5-number spacing for future flexibility