 ╭────────────────────────────────────────────────────────────────────────────────────────────────────╮ │
 │ Next Script Review: riva-015-deploy-or-restart-aws-gpu-instance.sh                                 │ │
 │                                                                                                    │ │
 │ What this script does:                                                                             │ │
 │ - Creates a new AWS EC2 GPU instance (g4dn.xlarge with Tesla T4)                                   │ │
 │ - Sets up security groups for SSH/HTTP/gRPC access                                                 │ │
 │ - Creates and attaches EBS storage volume (200GB for model cache)                                  │ │
 │ - Configures instance with Ubuntu 24.04 AMI optimized for GPU workloads                            │ │
 │ - Updates the .env file with the new instance ID and IP address                                    │ │
 │                                                                                                    │ │
 │ Key actions it will perform:                                                                       │ │
 │ 1. Validate AWS credentials and configuration from your fresh .env                                 │ │
 │ 2. Create security group allowing SSH (22), HTTP (8000, 8443, 9000), and gRPC (50051)              │ │
 │ 3. Launch g4dn.xlarge instance with your SSH key (dbm-sep-12-2025)                                 │ │
 │ 4. Create and attach 200GB EBS volume for NIM model caching                                        │ │
 │ 5. Wait for instance to be running and reachable                                                   │ │
 │ 6. Update .env with new GPU_INSTANCE_ID and GPU_INSTANCE_IP                                        │ │
 │                                                                                                    │ │
 │ Expected results:                                                                                  │ │
 │ - New EC2 instance running Ubuntu 24.04                                                            │ │
 │ - Instance accessible via SSH with your key                                                        │ │
 │ - Security groups configured for Riva services                                                     │ │
 │ - .env updated with instance details                                                               │ │
 │ - System ready for NVIDIA driver installation (next script)                                        │ │
 │                                                                                                    │ │
 │ This should be safe to run since you're starting fresh and it only creates new AWS resources       │ │
 │ without modifying existing ones.                                                                   │ │
 ╰────────────────────────────────────────────────────────────────────────────────────────────────────╯
