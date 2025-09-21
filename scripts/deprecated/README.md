# Deprecated Scripts

This directory contains scripts that are no longer recommended for use.

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

**Date Deprecated**: September 21, 2025

