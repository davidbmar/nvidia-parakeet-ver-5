#!/usr/bin/env python3
"""
Production HTTPS WebSocket Server for RNN-T Transcription
Integrates all our performance fixes and optimizations

Features:
- SSL/HTTPS support with self-signed certificates
- WebSocket transcription with our optimized components
- Static file serving for web UI
- Real SpeechBrain RNN-T transcription
- Performance monitoring and logging
"""

import ssl
import asyncio
import logging
import sys
import os
import time
from pathlib import Path

# Add project root to Python path
PROJECT_ROOT = Path(__file__).parent
sys.path.insert(0, str(PROJECT_ROOT))

# FastAPI imports
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request, File, UploadFile
from fastapi.staticfiles import StaticFiles
from fastapi.responses import HTMLResponse, JSONResponse
import uvicorn

# Load environment variables
from dotenv import load_dotenv
load_dotenv()

# Our optimized WebSocket components
from websocket.websocket_handler import WebSocketHandler

# Setup logging
# Try to use /opt/rnnt/logs, fallback to home directory if not writable
log_file_path = '/opt/rnnt/logs/https-server.log'
try:
    os.makedirs('/opt/rnnt/logs', exist_ok=True)
    with open(log_file_path, 'a') as f:
        pass  # Test write permissions
except (PermissionError, OSError):
    # Fallback to home directory
    alt_log_dir = os.path.expanduser('~/rnnt/logs')
    os.makedirs(alt_log_dir, exist_ok=True)
    log_file_path = os.path.join(alt_log_dir, 'https-server.log')

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(log_file_path, mode='a')
    ]
)
logger = logging.getLogger(__name__)

# Create FastAPI app
app = FastAPI(
    title="RNN-T Production HTTPS Server",
    description="Production WebSocket server for real-time speech transcription",
    version="1.0.0"
)

# Global WebSocket handler
websocket_handler = None

# Riva configuration from environment
RIVA_HOST = os.getenv('RIVA_HOST', 'localhost')
RIVA_PORT = os.getenv('RIVA_PORT', '50051')

@app.on_event("startup")
async def startup_event():
    """Initialize services on startup"""
    global websocket_handler
    
    logger.info("🚀 Starting Riva ASR HTTPS Server...")
    logger.info(f"Riva ASR Server: {RIVA_HOST}:{RIVA_PORT}")
    
    # Create necessary directories
    try:
        os.makedirs('/opt/rnnt/logs', exist_ok=True)
    except PermissionError:
        # Fallback to home directory if /opt/rnnt is not writable
        alt_log_dir = os.path.expanduser('~/rnnt/logs')
        os.makedirs(alt_log_dir, exist_ok=True)
        logger.info(f"Using alternative log directory: {alt_log_dir}")
    
    # Initialize WebSocket handler (Riva client will be initialized on first connection)
    try:
        # Pass None for model since we're using Riva
        websocket_handler = WebSocketHandler(None)
        logger.info("✅ WebSocket handler initialized for Riva ASR")
        logger.info(f"📡 Will connect to Riva at {RIVA_HOST}:{RIVA_PORT}")
    except Exception as e:
        logger.error(f"❌ Failed to initialize WebSocket handler: {e}")
        sys.exit(1)
    
    logger.info("🎉 Server startup complete - ready for transcription!")

@app.get("/")
async def root():
    """Root endpoint"""
    return {
        "service": "Riva ASR WebSocket Server", 
        "status": "active",
        "version": "2.0.0",
        "riva_host": f"{RIVA_HOST}:{RIVA_PORT}",
        "features": [
            "Real-time WebSocket transcription",
            "NVIDIA Riva Parakeet RNNT model",
            "Remote GPU processing via gRPC", 
            "Enhanced VAD with ZCR",
            "Word-level timing from Riva",
            "SSL/HTTPS support"
        ]
    }

@app.get("/health")
async def health_check():
    """Health check endpoint"""
    try:
        # Check if handler is ready (Riva connection tested on first use)
        
        return {
            "status": "healthy",
            "riva_server": f"{RIVA_HOST}:{RIVA_PORT}",
            "websocket_handler": "active" if websocket_handler else "inactive"
        }
    except Exception as e:
        logger.error(f"Health check failed: {e}")
        return {"status": "unhealthy", "error": str(e)}

@app.get("/ws/status")
async def websocket_status():
    """WebSocket status endpoint"""
    return {
        "websocket_endpoint": "/ws/transcribe",
        "protocol": "WSS (WebSocket Secure)",
        "status": "active" if websocket_handler else "inactive",
        "active_connections": len(websocket_handler.active_connections) if websocket_handler else 0
    }

@app.post("/transcribe/file")
async def transcribe_file(file: UploadFile = File(...)):
    """File upload endpoint for audio transcription"""
    try:
        # Read the uploaded file
        file_content = await file.read()
        
        # For now, return a mock response since we have a mock Riva service
        # In a real implementation, this would process the audio file
        response = {
            "status": "success",
            "filename": file.filename,
            "transcript": "This is a mock transcription result from the uploaded audio file. The actual Riva service would process the audio and return real transcription results.",
            "confidence": 0.95,
            "duration": "estimated 10 seconds",
            "service": "mock-riva-file-upload",
            "timestamp": time.time()
        }
        
        logger.info(f"📁 File upload transcription: {file.filename} ({len(file_content)} bytes)")
        
        return response
        
    except Exception as e:
        logger.error(f"❌ File transcription error: {e}")
        return {
            "status": "error",
            "message": str(e),
            "service": "riva-file-upload"
        }

@app.websocket("/ws/transcribe")
async def websocket_transcribe(websocket: WebSocket):
    """WebSocket endpoint for real-time transcription"""
    if not websocket_handler:
        logger.error("WebSocket handler not initialized")
        await websocket.close(code=1011, reason="Server not ready")
        return
    
    # Extract client ID from query params
    client_id = websocket.query_params.get('client_id', f'client_{id(websocket)}')
    
    logger.info(f"🔌 WebSocket connection attempt: {client_id}")
    
    try:
        # Accept connection
        await websocket.accept()
        logger.info(f"✅ WebSocket connected: {client_id}")
        
        # Handle the WebSocket session using our optimized handler
        await websocket_handler.handle_websocket(websocket, client_id)
        
    except WebSocketDisconnect:
        logger.info(f"🔌 WebSocket disconnected: {client_id}")
    except Exception as e:
        logger.error(f"❌ WebSocket error for {client_id}: {e}")
        try:
            await websocket.close(code=1011, reason="Server error")
        except:
            pass

# Mount static files for web UI
static_dir = None
for path in ['/opt/rnnt/static', './static', '../static']:
    if os.path.exists(path):
        static_dir = path
        break

if static_dir:
    app.mount("/static", StaticFiles(directory=static_dir), name="static")
    logger.info(f"📁 Static files mounted at /static from {static_dir}")
else:
    logger.warning("⚠️ No static directory found")

# Serve main UI at /ui
@app.get("/ui", response_class=HTMLResponse)
async def serve_ui():
    """Serve the main transcription UI"""
    if static_dir:
        ui_path = Path(static_dir) / "index.html"
        if ui_path.exists():
            return HTMLResponse(ui_path.read_text())
    
    return HTMLResponse("""
    <html>
        <body>
            <h1>RNN-T Transcription Server</h1>
            <p>Server is running but UI files not found.</p>
            <p>WebSocket endpoint: <code>wss://server/ws/transcribe</code></p>
        </body>
    </html>
    """)

@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    """Global exception handler"""
    logger.error(f"Global exception: {exc}")
    return JSONResponse(
        status_code=500,
        content={"error": "Internal server error", "detail": str(exc)}
    )

if __name__ == "__main__":
    # SSL Configuration - try multiple locations
    ssl_locations = [
        ("/opt/rnnt/server.crt", "/opt/rnnt/server.key"),
        (os.path.expanduser("~/rnnt/certs/server.crt"), os.path.expanduser("~/rnnt/certs/server.key")),
        (os.path.join(PROJECT_ROOT, "certs", "server.crt"), os.path.join(PROJECT_ROOT, "certs", "server.key"))
    ]
    
    ssl_cert_path = None
    ssl_key_path = None
    
    # Find SSL certificates
    for cert_path, key_path in ssl_locations:
        if os.path.exists(cert_path) and os.path.exists(key_path):
            ssl_cert_path = cert_path
            ssl_key_path = key_path
            break
    
    if not ssl_cert_path or not ssl_key_path:
        logger.error(f"❌ SSL certificates not found in any of these locations:")
        for cert_path, key_path in ssl_locations:
            logger.error(f"   - {cert_path}")
        logger.error("")
        logger.error("Run: ./scripts/generate-ssl-cert.sh to create certificates")
        sys.exit(1)
    
    logger.info(f"🔒 SSL Certificate: {ssl_cert_path}")
    logger.info(f"🔑 SSL Key: {ssl_key_path}")
    
    # Start HTTPS server
    try:
        logger.info("🚀 Starting HTTPS server on port 8443...")
        uvicorn.run(
            "rnnt-https-server:app",
            host="0.0.0.0",
            port=8443,
            ssl_keyfile=ssl_key_path,
            ssl_certfile=ssl_cert_path,
            ssl_version=ssl.PROTOCOL_TLS_SERVER,
            ssl_cert_reqs=ssl.CERT_NONE,
            log_level="info",
            access_log=True,
            loop="asyncio"
        )
    except Exception as e:
        logger.error(f"❌ Failed to start HTTPS server: {e}")
        sys.exit(1)