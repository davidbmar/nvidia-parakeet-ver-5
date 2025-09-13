# Script Renumbering Plan - 5-Number Spacing with Descriptive Names

## Current Issues
- Scripts numbered too close together (no room for additions)
- Multiple scripts with same numbers (041, 046, 047)
- Names could be more descriptive
- Need consistent logging integration

## New Numbering Scheme (5-number spacing)

### 000s - Setup and Configuration
- `riva-000-setup-configuration.sh` → `riva-005-setup-project-configuration.sh`
- `riva-000-run-complete-deployment.sh` → `riva-010-run-complete-deployment-pipeline.sh`

### 010s - Infrastructure Deployment  
- `riva-010-restart-existing-or-deploy-new-gpu-instance.sh` → `riva-015-deploy-or-restart-aws-gpu-instance.sh`
- `riva-015-configure-security-access.sh` → `riva-020-configure-aws-security-groups.sh`

### 020s - NVIDIA Driver Management
- `riva-020-download-nvidia-drivers.sh` → `riva-025-download-nvidia-gpu-drivers.sh`
- `riva-025-transfer-nvidia-drivers.sh` → `riva-030-transfer-drivers-to-gpu-instance.sh`
- `riva-030-reboot-gpu-instance.sh` → `riva-035-reboot-gpu-instance-after-drivers.sh`
- `riva-035-install-nvidia-drivers.sh` → `riva-040-install-nvidia-drivers-on-gpu.sh`

### 040s - Environment Setup
- `riva-041-prepare-environment.sh` → `riva-045-prepare-riva-environment.sh`
- `riva-041-fix-gpu-access.sh` → `riva-050-fix-gpu-docker-access.sh`

### 050s - NIM Container Management (CHOICE POINT)
- **Path A: Download Fresh**
  - `riva-046-stream-nim-to-s3.sh` → `riva-055-download-nim-container-from-nvidia.sh`
- **Path B: Restore from Backup** 
  - `riva-049-restore-nim-containers.sh` → `riva-055-restore-nim-container-from-s3-backup.sh`

### 060s - Container Deployment and Backup
- `riva-047-deploy-nim-simple.sh` → `riva-060-deploy-nim-container-for-asr.sh`
- `riva-048-backup-nim-containers.sh` → `riva-065-backup-nim-container-to-s3.sh`

### 070s - Riva Server Setup (Legacy Path)
- `riva-040-setup-riva-server.sh` → `riva-070-setup-traditional-riva-server.sh`
- `riva-042-download-models.sh` → `riva-075-download-traditional-riva-models.sh`
- `riva-043-deploy-models.sh` → `riva-080-deploy-traditional-riva-models.sh`
- `riva-044-start-riva-server.sh` → `riva-085-start-traditional-riva-server.sh`

### 090s - Application Deployment
- `riva-045-deploy-websocket-app.sh` → `riva-090-deploy-websocket-asr-application.sh`
- `riva-050-deploy-static-files.sh` → `riva-095-deploy-static-web-files.sh`

### 100s - Testing and Validation
- `riva-055-test-integration.sh` → `riva-100-test-basic-integration.sh`
- `riva-060-test-riva-connectivity.sh` → `riva-105-test-riva-server-connectivity.sh`
- `riva-065-test-file-transcription.sh` → `riva-110-test-audio-file-transcription.sh`
- `riva-070-test-streaming-transcription.sh` → `riva-115-test-realtime-streaming-transcription.sh`
- `riva-080-test-end-to-end-transcription.sh` → `riva-120-test-complete-end-to-end-pipeline.sh`

### 125s - Production Enablement
- `riva-075-enable-real-riva-mode.sh` → `riva-125-enable-production-riva-mode.sh`

### 999s - Cleanup
- `riva-999-destroy-all.sh` → `riva-999-destroy-all-resources.sh`

## Deprecated/Duplicate Scripts (TO REMOVE)
- `riva-046-save-nim-to-s3.sh` (duplicate functionality)
- `riva-047-deploy-nim-container.sh` (replaced by deploy-nim-simple)
- `riva-047-deploy-nim-from-s3.sh` (replaced by restore script)

## Key Changes
1. **5-number spacing** allows easy insertion of new scripts
2. **Descriptive names** make purpose immediately clear
3. **Logical grouping** by function (setup, drivers, containers, testing)
4. **Choice points clearly marked** (download vs restore)
5. **All scripts will use common logging library**
6. **Consistent naming pattern**: `riva-XXX-verb-descriptive-noun.sh`

## Implementation Order
1. Rename scripts in reverse order (999 → 000) to avoid conflicts
2. Update all internal references
3. Update documentation and README files
4. Test renamed scripts
5. Remove deprecated scripts