 ╭────────────────────────────────────────────────────────────────────────────────────────────────────╮ │
 │ Next Script Review: riva-020-configure-aws-security-groups-enhanced.sh                             │ │
 │                                                                                                    │ │
 │ What this script does:                                                                             │ │
 │ - Enhances the security group already created by script 015                                        │ │
 │ - Configures proper IP access control for Riva/NIM services                                        │ │
 │ - Adds your current IP address to access rules                                                     │ │
 │ - Sets up port access for SSH (22), gRPC (50051), HTTP (8000), WebSocket (8443), and NIM (9000)    │ │
 │                                                                                                    │ │
 │ Key actions it will perform:                                                                       │ │
 │ 1. Check that security group sg-067d1a8c14e164797 exists (from script 015)                         │ │
 │ 2. Detect your current public IP address                                                           │ │
 │ 3. Add security group rules for required ports                                                     │ │
 │ 4. Configure access from your IP and the GPU instance's IP                                         │ │
 │ 5. Update .env with authorized IPs list                                                            │ │
 │                                                                                                    │ │
 │ This script is SAFE to run because:                                                                │ │
 │ - It only modifies the existing security group (doesn't create new resources)                      │ │
 │ - It adds your current IP for secure access                                                        │ │
 │ - All ports are standard Riva/NIM service ports                                                    │ │
 │ - It's a security enhancement, not a risky operation                                               │ │
 │                                                                                                    │ │
 │ Expected outcome:                                                                                  │ │
 │ - Security group properly configured for all Riva services                                         │ │
 │ - Your IP address authorized for access                                                            │ │
 │ - .env updated with security configuration details                                                 │ │
 │                                                                                                    │ │
 │ Recommendation: Run this script next to complete the security setup before installing NVIDIA       │ │
 │ drivers.                                                                                           │ │
 ╰────────────────────────────────────────────────────────────────────────────────────────────────────╯ │
                       
