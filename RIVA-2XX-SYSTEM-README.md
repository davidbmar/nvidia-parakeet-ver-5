# RIVA 2XX WebSocket Real-Time Transcription System

## Overview

This directory contains a comprehensive, modular script suite (`./scripts/riva-2xx`) for setting up **real-time transcription in a browser** using **NVIDIA RIVA Parakeet RNNT models**.

The system implements a **Build Box vs Worker** architecture where:
- **Build Box** (no GPU): Runs scripts, prepares configs, orchestrates deployments
- **Workers** (GPU EC2): Run RIVA services and handle transcription workloads

## ✅ Currently Implemented Scripts

### Core Infrastructure (200-210)
- **✅ riva-200-bootstrap.{sh,md}** - Directory setup, .env configuration, logging system, artifact management
- **✅ riva-205-system-deps.{sh,md}** - OS dependencies, gRPC tools, log viewers (lnav, multitail)
- **✅ riva-210-python-venv.{sh,md}** - Python virtual environment and RIVA client libraries

### RIVA Server Setup (212-215)
- **✅ riva-212-worker-riva-setup.{sh,md}** - Ensure RIVA server running on worker instances
- **✅ riva-215-verify-riva-grpc.{sh,md}** - gRPC connectivity validation to workers

### WebSocket Bridge (220-240)
- **✅ riva-220-tls-terminator.{sh,md}** - HTTPS/WSS setup via Caddy/Nginx
- **✅ riva-225-bridge-config.{sh,md}** - WebSocket bridge configuration
- **⏳ riva-230-bridge-run** - Launch monitored WebSocket service
- **⏳ riva-235-frontend-deploy** - Browser UI deployment
- **⏳ riva-240-ws-smoke-test** - Automated testing with WAV replay

### ⏳ Advanced Features (245-285)
- **riva-245-browser-e2e-test** - Manual browser testing with KPI computation
- **riva-250+** - Advanced features (word timings, diarization, metrics, S3, load testing)

## 🛠️ Key Features Implemented

### Script Architecture
- **Numbering**: Increments of 5 (200, 205, 210) for easy insertion
- **Documentation**: Each `.sh` has comprehensive `.md` documentation
- **Idempotent**: Safe to re-run with state tracking in `./state/`
- **Modular**: Each script has a specific, focused purpose

### Logging System
- **Dual Output**: Step-specific logs + aggregated `./logs/riva-run.log`
- **JSON Events**: Machine-parseable events alongside human-readable logs
- **Real-time Monitoring**: Support for `tail -f ./logs/latest.log`, `lnav`, `multitail`
- **Color Coding**: Different log levels with color indicators

### Artifact Management
- **Centralized Storage**: All artifacts in `./artifacts/` with JSON manifest
- **Types**: System snapshots, test results, configurations, transcripts
- **Tracking**: Complete audit trail of all operations and outputs

### Environment Configuration
- **Comprehensive .env**: All settings centralized with validation
- **Security**: TLS/SSL support, secure certificate management
- **Flexibility**: Support for both NIM containers and traditional RIVA

## 🚀 Quick Start

### 1. Bootstrap the System
```bash
# Initialize directories, logging, and environment
./scripts/riva-200-bootstrap.sh
```

### 2. Install Dependencies
```bash
# Install OS packages and tools
./scripts/riva-205-system-deps.sh
```

### 3. Setup Python Environment
```bash
# Setup Python venv and RIVA libraries
./scripts/riva-210-python-venv.sh
```

### 4. Monitor Progress
```bash
# Watch all logs in real-time
tail -f ./logs/latest.log

# Use enhanced log viewer
lnav ./logs/latest.log

# Monitor multiple logs
multitail ./logs/riva-*.log
```

## 📁 Directory Structure

```
./
├── scripts/
│   ├── riva-2xx-common.sh          # Common functions library
│   ├── riva-200-bootstrap.{sh,md}  # ✅ Foundation setup
│   ├── riva-205-system-deps.{sh,md}# ✅ OS dependencies
│   ├── riva-210-python-venv.{sh,md}# ✅ Python environment
│   └── riva-2xx-*.{sh,md}          # ⏳ Additional scripts
├── logs/
│   ├── riva-run.log                # Aggregated log
│   ├── latest.log → riva-run.log   # Convenience symlink
│   └── riva-*-*.log                # Step-specific logs
├── state/
│   └── riva-*.ok                   # Completion markers
├── artifacts/
│   ├── manifest.json               # Artifact index
│   ├── system/                     # System configurations
│   ├── checks/                     # Health checks
│   ├── bridge/                     # WebSocket configs
│   └── tests/                      # Test results
└── .env                            # Environment configuration
```

## 🔧 Advanced Features

### JSON Event Logging
Every script emits structured JSON events for machine parsing:
```bash
# Extract only JSON events
grep -E '^\\{".*' ./logs/latest.log | jq

# Monitor specific event types
grep -E '"event": "validation_passed"' ./logs/latest.log
```

### Artifact Tracking
```bash
# View all artifacts
jq '.artifacts[]' ./artifacts/manifest.json

# Find specific artifact types
jq '.artifacts[] | select(.type == "system_info")' ./artifacts/manifest.json
```

### State Management
```bash
# Check which steps are completed
ls -la ./state/

# View step completion details
cat ./state/riva-200.ok
```

## 🔍 Monitoring and Debugging

### Log Watching Commands
```bash
# Live aggregated log
tail -f ./logs/latest.log

# Enhanced log viewer with syntax highlighting
lnav ./logs/latest.log

# Monitor all step logs simultaneously
multitail ./logs/riva-*.log

# Filter JSON events only
tail -f ./logs/latest.log | grep -E '^\\{".*' | jq
```

### Common Troubleshooting
```bash
# Check environment configuration
grep -E '^(RIVA_|WS_|TLS_)' .env

# Validate JSON in logs
jq . ./logs/riva-*-*.log 2>/dev/null || echo "No JSON found"

# Check artifact manifest integrity
jq . ./artifacts/manifest.json
```

## 📝 Environment Variables

Key variables configured by the system:
```bash
# WebSocket Bridge
WS_HOST=0.0.0.0
WS_PORT=8443
USE_TLS=true
TLS_DOMAIN=your.domain.com

# RIVA Connection (to workers)
RIVA_HOST=3.131.83.194
RIVA_PORT=50051
MOCK_MODE=false

# Features
DIARIZATION_MODE=turntaking
LOG_JSON=true
METRICS_PROMETHEUS=true
```

## 🤝 Contributing

To add new scripts to this system:

1. **Follow Naming Convention**: `riva-XXX-description.{sh,md}`
2. **Use Common Functions**: Source `riva-2xx-common.sh`
3. **Document Thoroughly**: Create comprehensive `.md` file
4. **Implement Logging**: Use `log_info`, `log_success`, etc.
5. **Track Artifacts**: Use `add_artifact` for outputs
6. **Mark Completion**: Use `mark_step_complete`

## 📞 Support

- **Logs**: Check `./logs/latest.log` for detailed execution logs
- **State**: Check `./state/` for completion status
- **Artifacts**: Check `./artifacts/manifest.json` for all outputs
- **Configuration**: Check `.env` for current settings

---

**Status**: Foundation scripts implemented and tested ✅
**Next**: Continue with connectivity validation and WebSocket bridge setup
**Architecture**: Production-ready with comprehensive logging, artifact management, and monitoring