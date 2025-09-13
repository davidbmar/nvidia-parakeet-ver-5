# Logging Framework Documentation

## 📊 Overview

The NVIDIA Parakeet Riva ASR deployment system includes a **production-grade logging framework** that provides comprehensive debugging, monitoring, and troubleshooting capabilities. This framework is designed to make it easy to determine what went wrong just by reading the logs.

## 🔍 Key Features

- **Structured Logging**: Organized in clear sections with timestamps
- **Command Tracking**: Every command executed with timing and full output
- **Error Context**: Complete error information with stack traces
- **Remote Operations**: Detailed SSH operation logging
- **Resource Monitoring**: CPU, memory, and GPU usage tracking
- **Automatic Log Files**: Unique timestamped files with process IDs

## 📁 File Structure

### Log File Naming Convention
```
logs/[script-name]_[timestamp]_pid[process-id].log
```

**Example:**
```
logs/riva-025-transfer-nvidia-drivers_20250906_144530_pid12347.log
```

### Directory Structure
```
logs/
├── riva-000-setup-configuration_20250906_143022_pid12345.log
├── riva-010-deploy-gpu-instance_20250906_143530_pid12346.log
├── riva-025-transfer-nvidia-drivers_20250906_144530_pid12347.log
├── riva-040-setup-riva-server_20250906_145012_pid12348.log
├── check-driver-status_20250906_150203_pid12349.log
└── test-logging_20250906_151024_pid12350.log
```

## 📋 Log File Anatomy

### 1. Session Header
Every log file starts with comprehensive session information:
```
=== Log session started at 2025-09-06 14:45:12 ===
Script: ./scripts/riva-025-transfer-nvidia-drivers.sh
PID: 12347
User: ubuntu
Host: ip-172-31-44-30
Working Directory: /home/ubuntu/nvidia-parakeet/scripts
Command Line: ./scripts/riva-025-transfer-nvidia-drivers.sh
=======================================================
```

### 2. Environment Information
Detailed environment context:
```
=== SECTION START: Environment Information ===
[2025-09-06 14:45:12.801] [INFO] Script: ./scripts/riva-025-transfer-nvidia-drivers.sh
[2025-09-06 14:45:12.803] [INFO] PID: 12347
[2025-09-06 14:45:12.806] [INFO] User: ubuntu
[2025-09-06 14:45:12.808] [INFO] Host: ip-172-31-44-30
[2025-09-06 14:45:12.824] [INFO] OS: Linux ip-172-31-44-30 6.14.0-1011-aws
[2025-09-06 14:45:12.827] [INFO] Working Directory: /home/ubuntu/nvidia-parakeet/scripts
[2025-09-06 14:45:12.829] [INFO] Log File: /home/ubuntu/nvidia-parakeet/logs/riva-025-transfer-nvidia-drivers_20250906_144530_pid12347.log
[2025-09-06 14:45:12.831] [INFO] Log Level: 20
[2025-09-06 14:45:12.833] [INFO] Shell: 5.2.21(1)-release
=== SECTION END: Environment Information (SUCCESS) ===
```

### 3. Section-Based Organization
Operations are organized in clear sections:
```
=== SECTION START: Configuration Validation ===
[2025-09-06 14:45:13.101] [INFO] Loading configuration from: /home/ubuntu/nvidia-parakeet/.env
[2025-09-06 14:45:13.103] [DEBUG] Configuration variable GPU_INSTANCE_ID = i-0abcd1234efgh5678
[2025-09-06 14:45:13.105] [DEBUG] Configuration variable GPU_INSTANCE_IP = 54.123.45.67
[2025-09-06 14:45:13.107] [SUCCESS] All required configuration variables present
=== SECTION END: Configuration Validation (SUCCESS) ===
```

### 4. Command Execution Logging
Every command is logged with complete details:
```
[2025-09-06 14:45:15.201] [STEP] 📋 Executing: Testing SSH connectivity to GPU instance
[2025-09-06 14:45:15.203] [DEBUG] Command: timeout 30 bash -c "</dev/tcp/54.123.45.67/22"
[2025-09-06 14:45:15.891] [SUCCESS] Testing SSH connectivity to GPU instance completed in 0.688s
```

### 5. Error Handling and Context
Comprehensive error information:
```
[2025-09-06 14:45:20.150] [STEP] 📋 Executing: Testing failing command (expected to fail)
[2025-09-06 14:45:20.152] [DEBUG] Command: ls /nonexistent/directory
[2025-09-06 14:45:20.162] [ERROR] Testing failing command (expected to fail) failed after 0.010s (exit code: 2)
[2025-09-06 14:45:20.164] [ERROR] Command: ls /nonexistent/directory
[2025-09-06 14:45:20.166] [ERROR] Error output:
[2025-09-06 14:45:20.168] [ERROR]   ls: cannot access '/nonexistent/directory': No such file or directory
```

### 6. Session Footer
Every session ends with summary information:
```
=== Log session ended at 2025-09-06 14:47:30 ===
Final exit code: 0
```

## 🛠️ Using the Logging Framework

### In Scripts
Scripts automatically use the logging framework by including:
```bash
# Load common logging framework
source "$SCRIPT_DIR/common-logging.sh"

# Start script with banner
log_script_start "Script Description"

# Use structured logging
log_section_start "Operation Name"
log_info "Information message"
log_execute "Description" "command to execute"
log_section_end "Operation Name"
```

### Available Log Functions
- `log_debug()` - Debug information (only visible at DEBUG level)
- `log_info()` - General information
- `log_warn()` - Warning messages
- `log_error()` - Error messages (non-fatal)
- `log_fatal()` - Fatal errors (script will exit)
- `log_success()` - Success confirmation
- `log_step()` - Step indicators with emoji
- `log_progress()` - Progress indicators

### Section Management
- `log_section_start "Name"` - Start a logical section
- `log_section_end "Name" [status]` - End section with optional status

### Command Execution
- `log_execute "description" "command"` - Execute with logging
- `log_execute_remote "description" "host" "command"` - Remote execution

### Validation and Testing
- `log_validate_config "file" "var1" "var2"` - Configuration validation
- `log_test_connectivity "host" "port" "timeout"` - Network testing

## 🔍 Log Analysis

### Quick Analysis Commands
```bash
# Find recent logs
ls -lat logs/ | head -10

# Look for errors in specific log
grep -A5 -B5 "ERROR\|FATAL" logs/script-name_*.log

# Find failed sections
grep "SECTION.*failed" logs/script-name_*.log

# Check timing information
grep "completed in\|failed after" logs/script-name_*.log

# Find specific sections
grep -A10 "=== SECTION START:" logs/script-name_*.log

# View error summary
grep -A20 "=== ERROR SUMMARY ===" logs/script-name_*.log
```

### Success Patterns
Look for these patterns to confirm successful operations:
```
[SUCCESS] Configuration validation completed
[SUCCESS] SSH connection successful
[SUCCESS] Driver installation appears successful
[SUCCESS] Riva server is running
✅ [Section Name] completed
```

### Warning Patterns
These indicate potential issues but script continues:
```
[WARN] Driver version mismatch - needs updating
[WARN] No installation success marker found
⚠️  [Warning message]
```

### Error Patterns
These indicate failures requiring attention:
```
[ERROR] Cannot connect to server
[FATAL] Configuration validation failed
❌ [Section Name] failed: [REASON]
=== ERROR SUMMARY ===
```

## 🎯 Debug Utilities

### Quick Status Check
```bash
# Check driver and system status with comprehensive logging
./scripts/check-driver-status.sh
```

This utility provides:
- SSH connectivity testing
- Driver version validation
- GPU accessibility verification
- Installation file status
- Log analysis with recommendations

### Test Logging Framework
```bash
# Test all logging capabilities
./scripts/test-logging.sh
```

This demonstrates:
- All log levels and functions
- Command execution logging
- Error handling
- Section management
- Configuration validation

## 📈 Performance and Resource Monitoring

### Resource Usage Logging
The framework automatically logs:
- Memory usage (used/total and percentage)
- Disk usage for current directory
- CPU core count and load average
- GPU information when available

### Command Timing
Every executed command includes:
- Start time with millisecond precision
- End time and duration calculation
- Success/failure status
- Full output capture

### Remote Operation Monitoring
SSH operations include:
- Connection timing and timeout handling
- Command execution with context
- Error propagation and debugging information
- Resource usage on remote systems

## 🔧 Configuration

### Log Levels
Set `SCRIPT_LOG_LEVEL` environment variable:
- `10` - DEBUG (shows all messages including debug)
- `20` - INFO (default, shows info and above)
- `30` - WARN (shows warnings and errors only)
- `40` - ERROR (shows errors only)

### Log File Location
Logs are automatically stored in:
- `PROJECT_ROOT/logs/`
- Unique filename with timestamp and PID
- Automatic directory creation

### Error Handling
- Automatic error trap setup
- Stack trace generation on failures
- Clean exit handling with summaries
- Error context preservation

## 🆘 Troubleshooting with Logs

### Common Debugging Workflow
1. **Find the failing script**: `ls -lat logs/ | head -10`
2. **Examine the failure**: `cat logs/[failed-script]_*.log`
3. **Look for specific errors**: `grep -A5 -B5 "ERROR\|FATAL" logs/[script]_*.log`
4. **Find which section failed**: `grep "SECTION.*failed" logs/[script]_*.log`
5. **Check error context**: `grep -A20 "=== ERROR SUMMARY ===" logs/[script]_*.log`

### Remote Debugging
For issues on remote servers:
1. Check SSH connectivity logs
2. Review remote command execution details
3. Analyze resource usage on remote systems
4. Verify remote file operations and permissions

### Performance Analysis
1. Review command timing information
2. Check resource usage patterns
3. Identify bottlenecks in deployment process
4. Monitor GPU/driver operations

## 💡 Best Practices

### For Script Development
1. Always source `common-logging.sh` first
2. Use `log_script_start` to initialize logging
3. Organize operations in logical sections
4. Use appropriate log levels for different message types
5. Provide descriptive messages for command execution

### For Debugging
1. Start with recent log files first
2. Focus on ERROR and FATAL messages
3. Use section markers to navigate quickly
4. Check both command output and timing
5. Review environment information for context

### For Production
1. Monitor log directory size periodically
2. Archive old logs as needed
3. Use log analysis tools for patterns
4. Set appropriate log levels for performance
5. Include log analysis in monitoring systems

## 🔗 Integration

### With Monitoring Systems
Logs are structured for easy integration with:
- Log aggregation systems (ELK, Splunk)
- Monitoring tools (Prometheus, Grafana)
- Alerting systems (PagerDuty, OpsGenie)
- CI/CD pipelines for automated analysis

### With Troubleshooting Workflows
The logging framework supports:
- Automated error detection and classification
- Root cause analysis through detailed context
- Performance regression detection
- Deployment validation and verification

This comprehensive logging framework ensures that every deployment issue can be quickly identified, analyzed, and resolved using the detailed information captured in the structured log files.