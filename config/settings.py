#!/usr/bin/env python3
"""
Configuration settings for Riva ASR WebSocket Server
Loads configuration from environment variables with .env support
"""

import os
from typing import Optional
from pydantic import BaseSettings, Field
from dotenv import load_dotenv

# Load .env file if it exists
load_dotenv()


class RivaSettings(BaseSettings):
    """NVIDIA Riva ASR configuration"""
    host: str = Field(default="localhost", env="RIVA_HOST")
    port: int = Field(default=50051, env="RIVA_PORT")
    http_port: int = Field(default=8000, env="RIVA_HTTP_PORT")
    
    model: str = Field(default="conformer_en_US_parakeet_rnnt", env="RIVA_MODEL")
    language_code: str = Field(default="en-US", env="RIVA_LANGUAGE_CODE")
    enable_punctuation: bool = Field(default=True, env="RIVA_ENABLE_AUTOMATIC_PUNCTUATION")
    enable_word_offsets: bool = Field(default=True, env="RIVA_ENABLE_WORD_TIME_OFFSETS")
    
    ssl: bool = Field(default=False, env="RIVA_SSL")
    ssl_cert: Optional[str] = Field(default=None, env="RIVA_SSL_CERT")
    ssl_key: Optional[str] = Field(default=None, env="RIVA_SSL_KEY")
    api_key: Optional[str] = Field(default=None, env="RIVA_API_KEY")
    
    timeout_ms: int = Field(default=5000, env="RIVA_TIMEOUT_MS")
    max_retries: int = Field(default=3, env="RIVA_MAX_RETRIES")
    retry_delay_ms: int = Field(default=1000, env="RIVA_RETRY_DELAY_MS")
    
    max_batch_size: int = Field(default=8, env="RIVA_MAX_BATCH_SIZE")
    chunk_size_bytes: int = Field(default=8192, env="RIVA_CHUNK_SIZE_BYTES")
    enable_partial_results: bool = Field(default=True, env="RIVA_ENABLE_PARTIAL_RESULTS")
    partial_result_interval_ms: int = Field(default=300, env="RIVA_PARTIAL_RESULT_INTERVAL_MS")
    
    class Config:
        env_file = ".env"
        case_sensitive = False


class AppSettings(BaseSettings):
    """Application server settings"""
    host: str = Field(default="0.0.0.0", env="APP_HOST")
    port: int = Field(default=8443, env="APP_PORT")
    ssl_cert: str = Field(default="/opt/rnnt/certs/server.crt", env="APP_SSL_CERT")
    ssl_key: str = Field(default="/opt/rnnt/certs/server.key", env="APP_SSL_KEY")
    
    class Config:
        env_file = ".env"
        case_sensitive = False


class WebSocketSettings(BaseSettings):
    """WebSocket configuration"""
    max_connections: int = Field(default=100, env="WS_MAX_CONNECTIONS")
    ping_interval_s: int = Field(default=30, env="WS_PING_INTERVAL_S")
    max_message_size_mb: int = Field(default=10, env="WS_MAX_MESSAGE_SIZE_MB")
    
    class Config:
        env_file = ".env"
        case_sensitive = False


class AudioSettings(BaseSettings):
    """Audio processing settings"""
    sample_rate: int = Field(default=16000, env="AUDIO_SAMPLE_RATE")
    channels: int = Field(default=1, env="AUDIO_CHANNELS")
    encoding: str = Field(default="pcm16", env="AUDIO_ENCODING")
    max_segment_duration_s: int = Field(default=30, env="AUDIO_MAX_SEGMENT_DURATION_S")
    vad_enabled: bool = Field(default=True, env="AUDIO_VAD_ENABLED")
    vad_threshold: float = Field(default=0.5, env="AUDIO_VAD_THRESHOLD")
    
    class Config:
        env_file = ".env"
        case_sensitive = False


class ObservabilitySettings(BaseSettings):
    """Observability and monitoring settings"""
    log_level: str = Field(default="INFO", env="LOG_LEVEL")
    log_dir: str = Field(default="/opt/riva/logs", env="LOG_DIR")
    metrics_enabled: bool = Field(default=True, env="METRICS_ENABLED")
    metrics_port: int = Field(default=9090, env="METRICS_PORT")
    tracing_enabled: bool = Field(default=False, env="TRACING_ENABLED")
    tracing_endpoint: str = Field(default="http://localhost:4317", env="TRACING_ENDPOINT")
    
    class Config:
        env_file = ".env"
        case_sensitive = False


class AWSSettings(BaseSettings):
    """AWS integration settings"""
    region: str = Field(default="us-west-2", env="AWS_REGION")
    s3_bucket: Optional[str] = Field(default=None, env="AWS_S3_BUCKET")
    access_key_id: Optional[str] = Field(default=None, env="AWS_ACCESS_KEY_ID")
    secret_access_key: Optional[str] = Field(default=None, env="AWS_SECRET_ACCESS_KEY")
    
    class Config:
        env_file = ".env"
        case_sensitive = False


class Settings(BaseSettings):
    """Combined application settings"""
    debug_mode: bool = Field(default=False, env="DEBUG_MODE")
    test_audio_path: str = Field(default="/opt/riva/test_audio", env="TEST_AUDIO_PATH")
    
    # Sub-settings
    riva: RivaSettings = RivaSettings()
    app: AppSettings = AppSettings()
    websocket: WebSocketSettings = WebSocketSettings()
    audio: AudioSettings = AudioSettings()
    observability: ObservabilitySettings = ObservabilitySettings()
    aws: AWSSettings = AWSSettings()
    
    class Config:
        env_file = ".env"
        case_sensitive = False
    
    def get_riva_uri(self) -> str:
        """Get Riva server URI"""
        return f"{self.riva.host}:{self.riva.port}"
    
    def get_app_url(self) -> str:
        """Get application URL"""
        protocol = "https" if self.app.ssl_cert else "http"
        return f"{protocol}://{self.app.host}:{self.app.port}"


# Global settings instance
settings = Settings()


def print_settings():
    """Print current settings for debugging"""
    print("=" * 50)
    print("Current Configuration Settings")
    print("=" * 50)
    print(f"Riva Server: {settings.get_riva_uri()}")
    print(f"Riva Model: {settings.riva.model}")
    print(f"App Server: {settings.get_app_url()}")
    print(f"Debug Mode: {settings.debug_mode}")
    print(f"Log Level: {settings.observability.log_level}")
    print(f"Metrics Enabled: {settings.observability.metrics_enabled}")
    print("=" * 50)


if __name__ == "__main__":
    # Test configuration loading
    print_settings()