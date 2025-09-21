# RIVA-210-PYTHON-VENV: Setup Python Virtual Environment and RIVA Client Libraries

## What This Script Does

Sets up a dedicated Python virtual environment and installs all required Python packages for the RIVA WebSocket real-time transcription system:

- **Python Environment**: Creates isolated venv for RIVA dependencies
- **RIVA Client Libraries**: Installs nvidia-riva-client and dependencies
- **WebSocket Libraries**: Installs websockets, asyncio libraries
- **Audio Processing**: Installs numpy, scipy, librosa for audio handling
- **Web Framework**: Installs FastAPI, uvicorn for HTTP/WebSocket server
- **Utilities**: Installs requests, aiofiles, python-multipart

## Preconditions

- System dependencies script (riva-205) completed successfully
- Python 3.8+ installed on the system
- Internet connectivity for package downloads
- Virtual environment creation permissions

## Actions Taken

1. **Detect Python Version**:
   - Verify Python 3.8+ is available
   - Check for python3-venv package
   - Install python3-venv if needed

2. **Create Virtual Environment**:
   ```bash
   python3 -m venv ./venv-riva-ws
   source ./venv-riva-ws/bin/activate
   ```

3. **Upgrade Core Python Tools**:
   ```bash
   pip install --upgrade pip setuptools wheel
   ```

4. **Install RIVA Client Libraries**:
   ```bash
   pip install nvidia-riva-client
   pip install grpcio grpcio-tools
   ```

5. **Install WebSocket and Async Libraries**:
   ```bash
   pip install websockets
   pip install asyncio
   pip install aiofiles
   pip install python-multipart
   ```

6. **Install Web Framework**:
   ```bash
   pip install fastapi
   pip install uvicorn[standard]
   pip install jinja2
   ```

7. **Install Audio Processing Libraries**:
   ```bash
   pip install numpy
   pip install scipy
   pip install librosa
   pip install soundfile
   ```

8. **Install Utility Libraries**:
   ```bash
   pip install requests
   pip install python-dotenv
   pip install pydantic
   pip install pyyaml
   ```

9. **Install Development and Testing Tools**:
   ```bash
   pip install pytest
   pip install pytest-asyncio
   pip install black
   pip install flake8
   ```

10. **Create Activation Helper**:
    - Create convenient activation script
    - Add environment variable setup
    - Create deactivation helper

## Outputs/Artifacts

- **Virtual Environment**: ./venv-riva-ws/ with all dependencies
- **Activation Script**: ./activate-riva-ws.sh for easy environment setup
- **Requirements File**: ./requirements-riva-ws.txt with pinned versions
- **Python Environment Snapshot**: artifacts/system/python-env-snapshot.json
- **Package List**: Complete list of installed packages with versions

## Troubleshooting

**Issue**: python3-venv not found
**Solution**: Install python3-venv package:
```bash
sudo apt update
sudo apt install python3-venv
```

**Issue**: pip install fails with permission error
**Solution**: Ensure virtual environment is activated:
```bash
source ./venv-riva-ws/bin/activate
which pip  # Should show venv path
```

**Issue**: nvidia-riva-client installation fails
**Solution**: Check Python version and upgrade pip:
```bash
python --version  # Should be 3.8+
pip install --upgrade pip setuptools wheel
```

**Issue**: Audio library compilation errors
**Solution**: Install system audio development packages:
```bash
sudo apt install libsndfile1-dev libfftw3-dev
```

**Issue**: gRPC compilation issues
**Solution**: Install build dependencies:
```bash
sudo apt install build-essential python3-dev
```

## Environment Variables Setup

The activation script sets these environment variables:
```bash
export RIVA_VENV_ACTIVE=true
export PYTHONPATH="${PYTHONPATH}:$(pwd)/src"
export RIVA_PROJECT_ROOT="$(pwd)"
```

## Testing the Installation

After setup, test key components:

```bash
# Activate environment
source ./activate-riva-ws.sh

# Test RIVA client import
python -c "import riva; print('RIVA client available')"

# Test WebSocket library
python -c "import websockets; print('WebSockets available')"

# Test audio processing
python -c "import librosa; print('Audio processing available')"

# Test web framework
python -c "import fastapi; print('FastAPI available')"
```

## Next Step

```bash
./scripts/riva-215-verify-riva-grpc.sh
```

Ready when: Virtual environment activated, all packages installed successfully, and RIVA client can be imported without errors.