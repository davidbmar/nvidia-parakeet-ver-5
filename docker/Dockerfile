# Production RNN-T Transcription Server
# NVIDIA CUDA-enabled Docker container for SpeechBrain RNN-T

FROM nvidia/cuda:12.1-devel-ubuntu22.04

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV CUDA_VISIBLE_DEVICES=0

# Install system dependencies
RUN apt-get update && apt-get install -y \
    python3.10 \
    python3.10-dev \
    python3-pip \
    python3.10-venv \
    build-essential \
    ffmpeg \
    libsndfile1 \
    libsndfile1-dev \
    git \
    curl \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Set Python 3.10 as default
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.10 1
RUN update-alternatives --install /usr/bin/python python /usr/bin/python3.10 1

# Create app directory
WORKDIR /app

# Copy requirements first for better caching
COPY config/requirements.txt .

# Install Python dependencies
RUN pip3 install --no-cache-dir --upgrade pip wheel setuptools

# Install PyTorch with CUDA support
RUN pip3 install --no-cache-dir torch==2.1.0 torchaudio==2.1.0 --index-url https://download.pytorch.org/whl/cu121

# Install other requirements
RUN pip3 install --no-cache-dir -r requirements.txt

# Create directories
RUN mkdir -p /app/logs /app/models /app/temp

# Copy application code
COPY docker/rnnt-server.py .

# Create cache directories
RUN mkdir -p /tmp/speechbrain_cache

# Set environment variables for SpeechBrain
ENV SPEECHBRAIN_CACHE_DIR=/tmp/speechbrain_cache
ENV HF_DATASETS_CACHE=/tmp/speechbrain_cache/datasets
ENV TRANSFORMERS_CACHE=/tmp/speechbrain_cache/transformers

# Create startup script
RUN echo '#!/bin/bash\n\
echo "🚀 Starting Production RNN-T Server..."\n\
echo "GPU Available: $(python3 -c \"import torch; print(torch.cuda.is_available())\")"\n\
if [ "$(python3 -c \"import torch; print(torch.cuda.is_available())\")" = "True" ]; then\n\
    echo "GPU Device: $(python3 -c \"import torch; print(torch.cuda.get_device_name(0))\")" \n\
fi\n\
exec python3 rnnt-server.py' > /app/start.sh

RUN chmod +x /app/start.sh

# Expose port
EXPOSE 8000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

# Start the server
CMD ["/app/start.sh"]