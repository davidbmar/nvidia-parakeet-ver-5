# RIVA-215-VERIFY-RIVA-GRPC: Verify gRPC Connectivity to RIVA Server on Workers

## What This Script Does

Validates gRPC connectivity to RIVA servers running on GPU worker instances using the grpcurl tool installed in the previous step:

- **Worker Connectivity**: Tests SSH connectivity to GPU worker instances
- **gRPC Service Discovery**: Lists available gRPC services on RIVA server
- **Health Checks**: Validates RIVA server health and readiness
- **Model Validation**: Verifies Parakeet RNNT models are loaded and available
- **Connection Parameters**: Tests different gRPC connection options (SSL/plaintext)
- **Build Box Separation**: Confirms proper build box → worker communication

## Preconditions

- Python virtual environment (riva-210) setup completed
- grpcurl tool installed and functional
- RIVA_HOST configured in .env pointing to worker instance
- SSH connectivity to worker instances configured
- RIVA server running on worker with Parakeet models loaded

## Actions Taken

1. **Environment Validation**:
   - Verify RIVA_HOST and RIVA_PORT in .env
   - Check SSH connectivity to worker instances
   - Validate grpcurl installation

2. **Worker Instance Health Check**:
   ```bash
   ssh ubuntu@$RIVA_HOST "systemctl status riva-server || docker ps | grep riva"
   ```

3. **gRPC Service Discovery**:
   ```bash
   grpcurl -plaintext $RIVA_HOST:$RIVA_PORT list
   grpcurl -plaintext $RIVA_HOST:$RIVA_PORT list nvidia.riva.proto.RivaSpeechRecognition
   ```

4. **RIVA Server Health Check**:
   ```bash
   grpcurl -plaintext $RIVA_HOST:$RIVA_PORT \
     nvidia.riva.proto.RivaHealthCheck/GetHealth
   ```

5. **Model Availability Check**:
   ```bash
   grpcurl -plaintext $RIVA_HOST:$RIVA_PORT \
     nvidia.riva.proto.RivaSpeechRecognition/GetRivaSpeechRecognitionConfig
   ```

6. **ASR Model Validation**:
   - Test streaming ASR endpoint availability
   - Validate Parakeet RNNT model presence
   - Check model configuration parameters

7. **Connection Testing**:
   - Test both SSL and plaintext connections
   - Validate timeout and retry settings
   - Test connection persistence

8. **Performance Baseline**:
   - Measure gRPC call latency
   - Test concurrent connections
   - Validate throughput capacity

## Outputs/Artifacts

- **gRPC Health Report**: artifacts/checks/grpc-health-check.json
- **Service Discovery**: List of available gRPC services and methods
- **Model Configuration**: Current RIVA model settings and capabilities
- **Connection Metrics**: Latency and performance measurements
- **Validation Summary**: Pass/fail status for all connectivity tests

## Troubleshooting

**Issue**: grpcurl: failed to connect
**Solution**: Check RIVA server status on worker:
```bash
ssh ubuntu@$RIVA_HOST "docker ps | grep riva"
ssh ubuntu@$RIVA_HOST "netstat -tlnp | grep :50051"
```

**Issue**: SSH connection failed
**Solution**: Verify SSH key and worker instance:
```bash
ssh -i ~/.ssh/$SSH_KEY_NAME.pem ubuntu@$RIVA_HOST "echo OK"
```

**Issue**: No services found
**Solution**: Check RIVA server logs:
```bash
ssh ubuntu@$RIVA_HOST "docker logs \$(docker ps -q --filter ancestor=*riva*)"
```

**Issue**: Models not loaded
**Solution**: Check model loading status:
```bash
ssh ubuntu@$RIVA_HOST "docker exec \$(docker ps -q --filter ancestor=*riva*) riva_speech_recognition_server --print_config"
```

**Issue**: Connection timeout
**Solution**: Adjust timeout settings and check network:
```bash
grpcurl -max-time 30 -plaintext $RIVA_HOST:$RIVA_PORT list
```

## Testing Commands

Manual verification commands for troubleshooting:

```bash
# Test basic connectivity
grpcurl -plaintext $RIVA_HOST:$RIVA_PORT list

# Test health endpoint
grpcurl -plaintext $RIVA_HOST:$RIVA_PORT \
  nvidia.riva.proto.RivaHealthCheck/GetHealth

# Test ASR service
grpcurl -plaintext $RIVA_HOST:$RIVA_PORT \
  list nvidia.riva.proto.RivaSpeechRecognition

# Test model configuration
grpcurl -plaintext $RIVA_HOST:$RIVA_PORT \
  nvidia.riva.proto.RivaSpeechRecognition/GetRivaSpeechRecognitionConfig

# Test with SSL (if configured)
grpcurl $RIVA_HOST:$RIVA_PORT list
```

## Expected Results

**Successful Validation Shows**:
- ✅ SSH connectivity to worker instances
- ✅ RIVA server running and responding
- ✅ gRPC services available: `nvidia.riva.proto.*`
- ✅ Health check returns: `SERVING`
- ✅ ASR models loaded: `parakeet-rnnt-*`
- ✅ Low latency gRPC calls (< 100ms for health checks)

## Next Step

```bash
./scripts/riva-220-tls-terminator.sh
```

Ready when: All gRPC connectivity tests pass, RIVA server responds with model list, and health checks return SERVING status.