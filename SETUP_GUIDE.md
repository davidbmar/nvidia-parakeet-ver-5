# NVIDIA Parakeet ASR Setup Guide

## Quick Start: From Mock to Real Transcription

This guide helps you set up real NVIDIA Parakeet RNNT transcription via Riva/NIM ASR, transitioning from mock mode to production-ready speech recognition.

## Prerequisites

- **GPU**: NVIDIA GPU with 8GB+ VRAM (T4, V100, A10, RTX 3080+)
- **CUDA**: 11.8+ with compatible drivers
- **Docker**: 20.10+ with NVIDIA Container Toolkit
- **Python**: 3.8+
- **NGC Account**: For Riva model access (free at ngc.nvidia.com)

## Setup Flow

### Phase 1: Environment Setup
```bash
# 1. Clone and enter repository
git clone <your-repo>
cd nvidia-parakeet-3

# 2. Configure environment
./scripts/riva-000-setup-configuration.sh

# 3. Install dependencies
pip install -r requirements.txt
```

### Phase 2: Deploy Riva Server
```bash
# 4. Deploy Riva/NIM container with Parakeet
./scripts/riva-040-setup-riva-server.sh

# 5. Download and deploy Parakeet RNNT model
./scripts/riva-042-download-models.sh
./scripts/riva-043-deploy-models.sh

# 6. Start Riva server
./scripts/riva-044-start-riva-server.sh
```

### Phase 3: Validate Mock Mode
```bash
# 7. Deploy WebSocket app (starts in mock mode)
./scripts/riva-045-deploy-websocket-app.sh

# 8. Test integration with mock responses
./scripts/riva-055-test-integration.sh
```

### Phase 4: Enable Real Transcription
```bash
# 9. Test Riva connectivity
./scripts/riva-060-test-riva-connectivity.sh

# 10. Test file transcription
./scripts/riva-065-test-file-transcription.sh

# 11. Test streaming transcription
./scripts/riva-070-test-streaming-transcription.sh

# 12. Switch to real mode
./scripts/riva-075-enable-real-riva-mode.sh

# 13. Test end-to-end pipeline
./scripts/riva-080-test-end-to-end-transcription.sh
```

## Key Files & Configuration

### Environment Variables (.env)
```bash
# Riva Server Settings
RIVA_HOST=localhost          # Riva server host
RIVA_PORT=50051              # Riva gRPC port
RIVA_MODEL=conformer_en_US_parakeet_rnnt  # Parakeet model name

# WebSocket App Settings
APP_PORT=8443                # WebSocket server port
APP_HOST=0.0.0.0            # Bind address

# Mode Control
MOCK_MODE=true               # Set to false for real transcription
```

### Mock vs Real Mode

| Component | Mock Mode | Real Mode |
|-----------|-----------|-----------|
| **Location** | `websocket/transcription_stream.py:44` | Same file |
| **Setting** | `RivaASRClient(mock_mode=True)` | `RivaASRClient(mock_mode=False)` |
| **Behavior** | Returns fake phrases | Sends audio to Riva GPU |
| **Latency** | Instant (~10ms) | Real-time (~300ms partials) |
| **GPU Required** | No | Yes |
| **Riva Server** | Not needed | Required |

## Testing Your Setup

### 1. Direct Python Test
```python
# test_transcription.py
import asyncio
from src.asr.riva_client import RivaASRClient

async def test():
    client = RivaASRClient(mock_mode=False)
    if await client.connect():
        print("✅ Connected to Riva")
        models = await client._list_models()
        print(f"Available models: {models}")
    await client.close()

asyncio.run(test())
```

### 2. WebSocket Test
```bash
# Upload audio file via WebSocket
python test_websocket_upload.py sample.wav
```

### 3. Performance Validation
```bash
# Run full test suite
./scripts/riva-080-test-end-to-end-transcription.sh
```

## Performance Targets

| Metric | Target | Measurement |
|--------|--------|-------------|
| **Partial Latency** | ≤300ms p95 | First partial result |
| **Final Latency** | ≤800ms p95 | After end-of-speech |
| **WER (Clean)** | ≤12% | Word error rate |
| **Concurrency** | 50+ streams | Per GPU |
| **RTFx** | >5x | Real-time factor |

## Troubleshooting

### Riva Connection Failed
```bash
# Check Riva status
docker ps | grep riva
docker logs riva-speech

# Test direct connection
grpcurl -plaintext localhost:50051 list
```

### Model Not Found
```bash
# List deployed models
docker exec riva-speech riva_model_list

# Re-deploy Parakeet
./scripts/riva-043-deploy-models.sh
```

### Still Getting Mock Responses
```bash
# Verify mode setting
grep mock_mode websocket/transcription_stream.py

# Force real mode
sed -i 's/mock_mode=True/mock_mode=False/' websocket/transcription_stream.py

# Restart WebSocket server
./scripts/riva-045-deploy-websocket-app.sh
```

## Production Checklist

- [ ] Riva server deployed with GPU access
- [ ] Parakeet RNNT model loaded
- [ ] WebSocket app in real mode (`mock_mode=False`)
- [ ] SSL/TLS configured for production
- [ ] Monitoring and logs enabled
- [ ] Load testing completed
- [ ] Backup/rollback plan ready

## Next Steps

1. **Optimize**: Tune batch size, chunk size for your workload
2. **Scale**: Add load balancer for multiple Riva instances
3. **Monitor**: Set up Grafana dashboards for metrics
4. **Secure**: Enable mTLS between app and Riva
5. **Deploy**: Use Kubernetes for orchestration

## Support

- **Riva Docs**: https://docs.nvidia.com/deeplearning/riva/
- **NGC Models**: https://catalog.ngc.nvidia.com/models
- **Issues**: File in GitHub Issues with logs from `/logs/`