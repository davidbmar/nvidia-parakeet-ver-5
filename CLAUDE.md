# NVIDIA Parakeet RNNT via Riva ASR - Implementation Plan

## 📋 Current Status (Updated 2025-09-07)

✅ **M0 – Plan Locked**: Architecture mapped, ASR boundaries identified  
✅ **M1 – Riva Online**: NIM/Traditional Riva containers deployed with health checks  
✅ **M2 – Client Wrapper**: `src/asr/riva_client.py` implemented (665 lines) with streaming support  
🔄 **M3 – WS Integration**: WebSocket server exists, needs real Riva integration (mock mode ready)  
⏳ **M4 – Observability**: Basic logging in place, metrics implementation pending  
⏳ **M5 – Production Ready**: Security hardening and deployment validation pending  

## 🚀 Deployment Infrastructure Complete

- **60+ Scripts**: Complete deployment automation in `scripts/riva-*`
- **NIM + Traditional**: Both modern NIM containers and traditional Riva server support
- **AWS Integration**: Full EC2 GPU instance deployment with driver automation
- **Comprehensive Testing**: File transcription, streaming, end-to-end validation scripts

---

# 🛠 Development Best Practices & Standards

## 🔧 Configuration & Environment Management

• **Always use .env file** - Never hardcode configuration values
• **Start with .env.example** as template, copy to .env for local development
• **Ask users to configure secure values** (API keys, passwords, certificates) interactively
• **Never commit .env file** - keep it in .gitignore, only commit .env.example
• **Use environment variables as primary config source** with pydantic validation
• **Prompt for missing critical config** during setup scripts

## 📁 Script Organization & Execution Order

• **Number scripts sequentially** as `./scripts/riva-XXX-description.sh` where XXX is execution order
• **Design scripts for first-time checkout** - assume clean environment
• **Make scripts idempotent** - safe to run multiple times
• **Include prerequisite checks** at start of each script
• **Chain scripts logically** - each script sets up for the next one
• **Document execution order** in README or main script

## 📝 Comprehensive Logging Strategy

• **Log everything in scripts** - timestamps, actions, results, errors
• **Use structured log format** with consistent timestamp and level indicators
• **Write logs to files** AND console output for debugging
• **Include enough detail** so AI can diagnose issues from logs alone
• **Log environment state** before/after major operations
• **Use color coding** for different log levels (ERROR=red, SUCCESS=green, etc.)

## 🔄 Step-by-Step Development Process

• **Think smallest possible step** - break down complex tasks into atomic operations
• **Test manually first** - verify each step works by hand/command line
• **Implement in code** - write the actual implementation
• **Create test script** - automate validation of the implementation
• **Write validation script** - verify desired end state was reached
• **Have user execute** - run implementation script then validation script
• **Number appropriately** - place in correct sequence for first-time setup

## 🛡 Error Handling & Debugging

• **Log all errors with context** - what was being attempted, environment state
• **Include retry logic** with logged attempts
• **Validate prerequisites** and log missing dependencies
• **Create detailed error messages** that point to likely solutions
• **Log performance metrics** (timing, resource usage)
• **Include stack traces** in debug logs

## 🔒 Security & Configuration Safety

• **Prompt for sensitive values** - don't put in example files
• **Validate configuration** before proceeding with operations
• **Use secure defaults** where possible
• **Warn about insecure configurations** in development vs production
• **Encrypt sensitive data** at rest when possible

## 📊 Production Readiness Checklist

• **Health checks in every component** - can be monitored by ops teams
• **Graceful degradation** - system works even when dependencies are down
• **Resource cleanup** - scripts clean up after themselves on failure
• **Rollback capability** - ability to undo script actions
• **Monitoring integration** - logs can be ingested by monitoring systems

## 📜 Script Template Structure

```bash
#!/bin/bash
set -euo pipefail

# Script: riva-XXX-description.sh
# Purpose: What this script does
# Prerequisites: What needs to be done first
# Validation: How to verify success

source "$(dirname "$0")/riva-common-functions.sh"
load_config

log_info "🚀 Starting XXX operation..."
validate_prerequisites
perform_operation
validate_results  
log_success "✅ XXX operation completed successfully"
```

## 💻 Code Style & Structure

• **Always use comprehensive type hints** with `typing` module (`Dict[str, Any]`, `Optional[str]`, `AsyncGenerator`)
• **Write Google-style docstrings** with Args, Returns, and Yields sections
• **Use async/await consistently** throughout - this is an async-first codebase
• **Organize code in classes** with clear single responsibilities
• **Use enums for constants** instead of magic strings/numbers
• **Use dataclasses for configuration** objects

## ⚠️ Error Handling Patterns

• **Implement layered error handling** - catch specific exceptions first, general ones last
• **Always handle gRPC errors specifically** with `grpc.RpcError`
• **Provide graceful degradation** with mock modes and fallbacks
• **Create standardized error response formats** for consistent client handling
• **Implement retry logic** with configurable parameters and exponential backoff

## 🧪 Testing Philosophy

• **Test against real services** when possible, not just mocks
• **Include connection validation tests** before integration
• **Build in mock mode support** for offline development
• **Create end-to-end validation** with actual audio files
• **Use descriptive test file names** indicating purpose

---

# 🎯 High-Level Goals

Stand up a Riva/NIM ASR instance exposing Parakeet RNNT over gRPC.

Replace the local RNNT path in your repo with a thin Riva client wrapper that preserves your current JSON/WS contract (partials/finals).

Ship observability, tests, and load checks so you can trust latency, accuracy, and stability in prod.

Harden for security & failure modes (TLS, timeouts, retries, backpressure).

