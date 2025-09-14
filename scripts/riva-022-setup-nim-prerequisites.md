     ╭─────────────────────────────────────────────────────────────────────────────────────────────────╮
     │ Next Script: riva-022-setup-nim-prerequisites.sh                                                │
     │                                                                                                 │
     │ What this script does:                                                                          │
     │ - Validates NGC API key configuration (you already have this configured)                        │
     │ - Checks NIM container variables in .env                                                        │
     │ - Sets up Docker login to NVIDIA Container Registry (nvcr.io)                                   │
     │ - Configures NGC authentication for downloading NIM models                                      │
     │ - Prepares the system for NIM container deployment                                              │
     │                                                                                                 │
     │ This should run successfully because:                                                           │
     │ - ✅ NGC_API_KEY is already configured in .env:                                                  │
     │ nvapi-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX                          │
     │ - ✅ Script validates configuration and sets up Docker registry access                           │
     │ - ✅ Prepares the environment for the next step (GPU driver installation)                        │
     │                                                                                                 │
     │ Expected outcome:                                                                               │
     │ - Docker logged into nvcr.io registry                                                           │
     │ - NGC authentication configured                                                                 │
     │ - System ready for NVIDIA driver installation                                                   │
     │ - .env updated with NIM prerequisite status                                                     │
     │                                                                                                 │
     │ Recommendation: This is the logical next step after security configuration, as it prepares the  │
     │ NGC/Docker environment needed before installing GPU drivers and NIM containers.                 │
     │                                                                                                 │
     │ Alternative consideration:                                                                      │
     │ Based on our previous H100/T4 engine mismatch issues, you might want to consider branching to   │
     │ the T4-specific scripts in scripts/NIM-direct-Nvidia-deployment-T4/ after driver installation,  │
     │ rather than using the S3 cached models that caused problems earlier.                            │
     ╰─────────────────────────────────────────────────────────────────────────────────────────────────╯


