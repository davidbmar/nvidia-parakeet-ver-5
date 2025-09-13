#!/usr/bin/env python3
"""
Enhanced RNN-T Server with WebSocket Support - FIXED VERSION
Adds real-time audio streaming capabilities to the production server
Fixed: Proper disconnect handling to prevent infinite loops
"""

import os
import sys
import uuid
from pathlib import Path

# Add parent directory to path for imports
sys.path.append(str(Path(__file__).parent.parent))

# Import original server components but avoid route conflicts
try:
    from rnnt_server import (
        app, logger, RNNT_SERVER_PORT, RNNT_SERVER_HOST, RNNT_MODEL_SOURCE,
        MODEL_LOADED, MODEL_LOAD_TIME, LOG_LEVEL, DEV_MODE,
        asr_model, load_model, health_check, transcribe_file, transcribe_s3,
        torch, uvicorn
    )
except ImportError:
    # Try relative import if in docker directory
    import importlib.util
    spec = importlib.util.spec_from_file_location("rnnt_server", "rnnt-server.py")
    rnnt_server = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rnnt_server)
    
    # Import needed components
    app = rnnt_server.app
    logger = rnnt_server.logger
    RNNT_SERVER_PORT = rnnt_server.RNNT_SERVER_PORT
    RNNT_SERVER_HOST = rnnt_server.RNNT_SERVER_HOST
    RNNT_MODEL_SOURCE = rnnt_server.RNNT_MODEL_SOURCE
    MODEL_LOADED = rnnt_server.MODEL_LOADED
    MODEL_LOAD_TIME = rnnt_server.MODEL_LOAD_TIME
    LOG_LEVEL = rnnt_server.LOG_LEVEL
    DEV_MODE = rnnt_server.DEV_MODE
    asr_model = rnnt_server.asr_model
    load_model = rnnt_server.load_model
    health_check = rnnt_server.health_check
    transcribe_file = rnnt_server.transcribe_file
    transcribe_s3 = rnnt_server.transcribe_s3
    torch = rnnt_server.torch
    uvicorn = rnnt_server.uvicorn

# Import WebSocket components
from websocket.websocket_handler import WebSocketHandler
from fastapi import WebSocket, WebSocketDisconnect
from fastapi.staticfiles import StaticFiles
from starlette.websockets import WebSocketState

# Create WebSocket handler instance
ws_handler = None
active_connections = set()

@app.on_event("startup")
async def startup_event_enhanced():
    """Enhanced startup with WebSocket support"""
    global ws_handler
    
    logger.info("🚀 Starting Enhanced RNN-T Server with WebSocket Support")
    logger.info(f"Configuration: port={RNNT_SERVER_PORT}, model={RNNT_MODEL_SOURCE}")
    
    # Load model on startup
    await load_model()
    
    # Import the global asr_model after loading
    from rnnt_server import asr_model
    
    # Verify model is loaded
    if asr_model is None:
        logger.error("❌ ASR model failed to load - WebSocket transcription will not work")
        raise RuntimeError("ASR model not loaded")
    
    # Initialize WebSocket handler with loaded model
    ws_handler = WebSocketHandler(asr_model)
    logger.info("✅ WebSocket handler initialized with loaded model")

# Remove the original root route to avoid conflicts
original_routes = app.routes[:]
app.routes.clear()
for route in original_routes:
    if hasattr(route, 'path') and route.path == '/':
        continue  # Skip the original root route
    app.routes.append(route)

# Mount static files for web interface
app.mount("/static", StaticFiles(directory="static"), name="static")
app.mount("/examples", StaticFiles(directory="examples"), name="examples")

@app.get("/")
async def root_enhanced():
    """Enhanced root endpoint with WebSocket info"""
    return {
        "service": "Production RNN-T Server with WebSocket Streaming",
        "version": "2.0.0",
        "model": RNNT_MODEL_SOURCE,
        "status": "READY" if MODEL_LOADED else "LOADING",
        "architecture": "RNN-T Conformer",
        "gpu_available": torch.cuda.is_available(),
        "device": "cuda" if torch.cuda.is_available() else "cpu",
        "model_load_time": f"{MODEL_LOAD_TIME:.1f}s" if MODEL_LOAD_TIME else "not loaded",
        "endpoints": {
            "rest": ["/health", "/transcribe/file", "/transcribe/s3"],
            "websocket": ["/ws/transcribe"],
            "web": ["/static/index.html", "/examples/simple-client.html"]
        },
        "features": {
            "real_time_streaming": True,
            "word_level_timestamps": True,
            "partial_results": True,
            "vad": True
        },
        "note": "Production-ready speech recognition with real-time streaming"
    }

@app.websocket("/ws/transcribe")
async def websocket_endpoint(websocket: WebSocket):
    """
    WebSocket endpoint for real-time audio streaming
    
    Protocol:
    - Binary messages: PCM16 audio data
    - JSON messages: Control commands
    - Responses: JSON transcription results
    """
    client_id = websocket.query_params.get('client_id', str(uuid.uuid4()))
    
    try:
        # Accept connection
        await ws_handler.connect(websocket, client_id)
        active_connections.add(client_id)
        
        # Handle messages
        while True:
            try:
                # Check if connection is still open before receiving
                if websocket.client_state != WebSocketState.CONNECTED:
                    logger.info(f"WebSocket client {client_id} connection closed")
                    break
                    
                # Receive message (binary or text)
                message = await websocket.receive()
                
                # Check for disconnect message
                if "type" in message and message["type"] == "websocket.disconnect":
                    logger.info(f"WebSocket client {client_id} sent disconnect")
                    break
                
                if "bytes" in message:
                    # Binary audio data
                    await ws_handler.handle_message(
                        websocket, 
                        client_id, 
                        message["bytes"]
                    )
                elif "text" in message:
                    # JSON control message
                    await ws_handler.handle_message(
                        websocket,
                        client_id,
                        message["text"]
                    )
                    
            except WebSocketDisconnect:
                logger.info(f"WebSocket client {client_id} disconnected")
                break
            except Exception as e:
                # Log error but don't try to send if connection might be closed
                logger.error(f"WebSocket message error for {client_id}: {e}")
                
                # Only try to send error if connection is still open
                if websocket.client_state == WebSocketState.CONNECTED:
                    try:
                        await ws_handler.send_error(websocket, str(e))
                    except:
                        # If send fails, connection is closed
                        break
                else:
                    # Connection closed, exit loop
                    break
                    
    except Exception as e:
        logger.error(f"WebSocket connection error for {client_id}: {e}")
    finally:
        # Clean disconnect
        active_connections.discard(client_id)
        await ws_handler.disconnect(client_id)
        
        # Ensure WebSocket is closed properly
        if websocket.client_state == WebSocketState.CONNECTED:
            try:
                await websocket.close()
            except:
                pass  # Already closed
        
        logger.info(f"WebSocket client {client_id} cleanup complete")

@app.get("/ws/status")
async def websocket_status():
    """Get WebSocket server status"""
    return {
        "status": "active",
        "websocket_ready": ws_handler is not None,
        "model_loaded": MODEL_LOADED,
        "active_connections": len(active_connections),
        "gpu_available": torch.cuda.is_available()
    }

# Main execution
if __name__ == "__main__":
    uvicorn.run(
        app,
        host=RNNT_SERVER_HOST,
        port=RNNT_SERVER_PORT,
        log_level=LOG_LEVEL.lower(),
        reload=DEV_MODE
    )