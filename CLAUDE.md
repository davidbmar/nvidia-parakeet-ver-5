# NVIDIA Parakeet RNNT via Riva ASR

## 📋 Current Status

✅ **Riva Deployed**: NIM/Traditional Riva containers with health checks
✅ **Client Wrapper**: `src/asr/riva_client.py` with streaming support
✅ **WebSocket Bridge**: Deployed at `/opt/riva/nvidia-parakeet-ver-6/`
✅ **60+ Scripts**: Complete deployment automation in `scripts/riva-*`
✅ **AWS Integration**: EC2 GPU instance deployment with driver automation

---

# 🛠 Development Standards

## 🔧 Configuration (.env file)

**Core Rules:**
- ALL configuration in `.env` file - **never hardcode values**
- Load early: `source "$(dirname "$0")/riva-common-functions.sh"; load_environment`
- Prompt and persist missing values: Update `.env` when user provides config interactively
- Use `require_env_vars` to validate required variables exist

**Script Pattern:**
```bash
#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/riva-common-functions.sh"
load_environment
require_env_vars "RIVA_HOST" "RIVA_PORT" "APP_PORT"
```

## 📁 Script Organization

- **Sequential numbering**: `riva-XXX-description.sh` (XXX = execution order)
- **Idempotent design**: Safe to run multiple times
- **Prerequisite checks**: Validate dependencies before proceeding
- **Chain logically**: Each script prepares for the next

## 📝 Logging

- Log timestamps, actions, results, errors
- Use color coding: ERROR=red, SUCCESS=green, INFO=blue
- Include context for AI diagnosis from logs alone

## 💻 Code Style

- **Type hints**: `Dict[str, Any]`, `Optional[str]`, `AsyncGenerator`
- **Async-first**: Use `async/await` consistently
- **Google-style docstrings**: Args, Returns, Yields sections
- **Dataclasses**: For configuration objects
- **Error handling**: Catch specific exceptions first, include retry logic

## 📜 Script Template

```bash
#!/bin/bash
set -euo pipefail

source "$(dirname "$0")/riva-common-functions.sh"
load_environment
require_env_vars "VAR1" "VAR2"

log_info "🚀 Starting operation..."
validate_prerequisites
perform_operation
log_success "✅ Completed"
```

---

# 🎯 Goals

Deploy Riva/NIM ASR with Parakeet RNNT over gRPC. Provide WebSocket bridge preserving JSON contract (partials/finals). Production-ready with observability, tests, TLS, timeouts, retries.

