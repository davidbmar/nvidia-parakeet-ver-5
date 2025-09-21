  Now for the From Scratch Deployment Guide:

  🚀 NVIDIA Parakeet RIVA Deployment - From Scratch

  If starting fresh, run these scripts in order:

  Phase 1: Infrastructure Setup

  # 1. Copy .env.example to .env and configure your settings
  cp .env.example .env
  # Edit .env with your AWS credentials, regions, SSH keys, etc.

  # 2. Validate environment configuration
  ./scripts/riva-000-validate-environment.sh

  # 3. Create AWS EC2 GPU instance  
  ./scripts/riva-001-create-gpu-instance.sh

  # 4. Setup security groups and networking
  ./scripts/riva-002-setup-security.sh

  Phase 2: GPU Instance Preparation

  # 5. Install GPU drivers and Docker
  ./scripts/riva-010-setup-gpu-drivers.sh

  # 6. Download RIVA containers and models from S3
  ./scripts/riva-020-download-containers.sh

  # 7. Download Parakeet model files
  ./scripts/riva-030-download-models.sh

  Phase 3: RIVA Model Deployment

  # 8. Setup RIVA QuickStart environment
  ./scripts/riva-040-setup-quickstart.sh

  # 9. Deploy .riva model files to proper repository structure
  ./scripts/riva-050-deploy-models.sh

  # 10. Configure RIVA for ASR-only service
  ./scripts/riva-060-configure-asr.sh

  Phase 4: Start Services

  # 11. Start RIVA server with deployed models
  # Use QuickStart approach (the working method we found):
  ssh -i ~/.ssh/your-key.pem ubuntu@YOUR-GPU-IP
  cd /opt/riva/riva_quickstart_2.19.0
  ./riva_start.sh

  Phase 5: Validation

  # 12. Test RIVA connectivity and services
  ./scripts/riva-090-test-connectivity.sh

  # 13. Run end-to-end ASR test with sample audio
  ./scripts/riva-095-test-asr.sh

  🔑 Key Working Configuration

  The successful approach we discovered:
  - ✅ Use RIVA QuickStart structure (not manual Triton configs)
  - ✅ Let RIVA handle .riva file deployment internally
  - ✅ Start with riva_start.sh (not custom Triton commands)
  - ✅ Models accessible on YOUR-GPU-IP:50051 via gRPC

  This gives you a complete, reproducible Parakeet RIVA deployment!
