# RIVA-200-BOOTSTRAP: WebSocket Real-Time Transcription System Bootstrap

## What This Script Does

Sets up the foundational infrastructure for the RIVA WebSocket real-time transcription system:

- **Directory Structure**: Creates logs/, state/, artifacts/ directories with proper subdirectories
- **Environment Configuration**: Initializes or validates .env file with WebSocket-specific settings
- **Logging Infrastructure**: Sets up comprehensive logging system with JSON event support
- **Artifact Management**: Initializes manifest.json for tracking all test results and artifacts
- **State Tracking**: Prepares state management for idempotent script execution

## Preconditions

- Working directory should be the project root
- .env.example file should exist (will be copied to .env if needed)
- User should be ready to configure WebSocket-specific settings

## Actions Taken

1. **Create Directory Structure**:
   ```
   ./logs/          # Step-specific and aggregated logs
   ./state/         # Completion markers for each script step
   ./artifacts/     # All test results, configs, transcripts
     ├── system/    # System configurations and snapshots
     ├── checks/    # Health checks and validation results
     ├── bridge/    # WebSocket bridge configurations
     └── tests/     # Test results, audio files, transcripts
   ```

2. **Initialize Environment Configuration**:
   - Copy .env.example to .env (if .env doesn't exist)
   - Add WebSocket-specific environment variables:
     ```bash
     # WebSocket Bridge Configuration
     WS_HOST=0.0.0.0
     WS_PORT=8443
     USE_TLS=true
     TLS_DOMAIN=your.domain.com
     ALLOW_ORIGINS=https://your.domain.com
     FRONTEND_URL=https://your.domain.com

     # RIVA Connection (pointing to worker)
     RIVA_HOST=3.131.83.194  # Worker GPU instance
     RIVA_PORT=50051
     MOCK_MODE=false

     # Transcription Settings
     RIVA_ASR_MODEL=parakeet-rnnt-xxl
     RIVA_ENABLE_WORD_TIMES=true
     RIVA_ENABLE_CONFIDENCE=true

     # Additional Features
     DIARIZATION_MODE=turntaking
     LOG_JSON=true
     METRICS_PROMETHEUS=true
     S3_SAVE=false
     ```

3. **Initialize Logging System**:
   - Create symlink: ./logs/latest.log → ./logs/riva-run.log
   - Setup dual logging: step-specific + aggregated
   - Configure JSON event logging for machine parsing

4. **Initialize Artifact Management**:
   - Create manifest.json with proper schema
   - Setup artifact directory structure
   - Prepare for KPI tracking and test result storage

## Outputs/Artifacts

- **Directory Structure**: Complete directory tree for RIVA 2xx system
- **Configuration File**: .env with WebSocket-specific settings
- **Logging Infrastructure**: Ready for all subsequent scripts
- **Manifest File**: artifacts/manifest.json initialized
- **State Tracking**: Prepared for idempotent script execution

## Troubleshooting

**Issue**: Permission denied creating directories
**Solution**: Ensure you're running from project root with write permissions

**Issue**: .env.example not found
**Solution**: Verify you're in the correct project directory

**Issue**: Environment variables not being set
**Solution**: Check .env file format and ensure no syntax errors

## Next Step

```bash
./scripts/riva-205-system-deps.sh
```

Ready when: Directories created, .env configured, logging initialized, and you can see JSON events in logs.