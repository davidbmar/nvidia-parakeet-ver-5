# RIVA-086 — Install RIVA ASR Models (Traditional RIVA)

**Goal:** Populate the RIVA model repository with one or more ASR models (e.g., Parakeet RNNT), then refresh the running RIVA container so models are available to clients.

## Prereqs
- RIVA container is already running (see `riva-085-start-traditional-riva-server.sh`)
- Host has: `aws`, `docker`, `jq`, `tar`, `grpcurl`, and either `sha256sum` or `shasum -a 256`
- Model repository is mounted into the container (host path in `.env`)

## Required `.env` keys
```bash
GPU_INSTANCE_IP=18.118.130.44
RIVA_CONTAINER_NAME=riva-server
RIVA_GRPC_PORT=50051
RIVA_HTTP_HEALTH_PORT=8000
RIVA_MODEL_REPO_HOST_DIR=/opt/riva/models
RIVA_ASR_MODEL_S3_URI=s3://...parakeet-rnnt...v8.1.tar.gz
RIVA_ASR_MODEL_NAME=parakeet-rnnt-en-us
RIVA_ASR_LANG_CODE=en-US
AWS_REGION=us-east-1
```

## Optional `.env` keys
```bash
AWS_PROFILE=
LOG_DIR=./logs
LOG_LEVEL=INFO # DEBUG|INFO|WARN|ERROR
FORCE=0 # 1 to overwrite existing install
DRY_RUN=0 # 1 to simulate
RETRY_MAX=3
RETRY_DELAY_SECONDS=5
RIVA_ASR_MODEL_SHA256= # if provided, integrity verified
```

## What the script does
1. **Config Wizard (optional):** asks for any missing values and, with your consent, writes them to `.env` atomically (with a timestamped backup and a diff preview). Headless CI can use `--write-env --yes`.
2. **Validation:** verifies tools, container health, GPU visibility, AWS creds, repo writability, and disk space.
3. **Acquire artifact:** downloads the model `.tar.gz` from S3, optionally verifies `SHA256`.
4. **Stage & normalize:** extracts into a staging area, aligns permissions, detects whether conversion is required.
5. **Convert (if needed):** runs `riva-build` **inside** the container to produce a deployable bundle.
6. **Install (atomic):** moves staged deployable into `/asr/<RIVA_ASR_MODEL_NAME>`. If existing and `FORCE=1`, backs it up to `.backup/`.
7. **Refresh & validate:** restarts the RIVA container, confirms health, and lists ASR config via `grpcurl`.
8. **Manifest:** writes `deployment_manifest.json` with model metadata.
9. **Next steps:** prints the follow-up script(s) to run and diagnostics path if something failed.

## Typical usage
```bash
# Interactive: fill in missing keys and write to .env
./scripts/riva-132-install-riva-models.sh --wizard

# CI/headless: permit .env writes non-interactively and accept prompts
./scripts/riva-132-install-riva-models.sh --no-wizard --write-env --yes

# Dry-run (no side effects)
DRY_RUN=1 ./scripts/riva-132-install-riva-models.sh --wizard

# Force overwrite existing installation
./scripts/riva-132-install-riva-models.sh --force

# Use alternate .env file
./scripts/riva-132-install-riva-models.sh --env-file /path/to/custom.env --wizard
```

## Idempotency & rollback
- If the model directory already exists, the script skips install unless `FORCE=1`.
- On `--force`, it moves the existing directory to `.backup/<name>-<timestamp>` before replacing.
- If anything fails mid-install, it attempts to restore the backup and prints instructions.

## Notes
- The script never hardcodes: all values come from `.env` (or CLI/env overrides).
- Secrets are redacted in logs.
- All operations are logged to `./logs/riva-086-*.log`.

## Troubleshooting
- **"Container not running"** → Start via `riva-085-start-traditional-riva-server.sh`.
- **"Model not found" in clients** → Re-run riva-086 with `--force`, ensure correct `RIVA_ASR_MODEL_NAME`, then validate gRPC config.
- **AWS permission issues** → Check `AWS_PROFILE`/`AWS_REGION`, run `aws sts get-caller-identity`.

## Success criteria:
- `/opt/riva/models/asr/<RIVA_ASR_MODEL_NAME>` exists and is non-empty
- Triton health: SERVING
- ASR config lists the model via grpcurl
- Test client can transcribe a short WAV without "model not available"