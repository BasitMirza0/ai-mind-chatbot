from pathlib import Path
from typing import Literal

from pydantic import Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=Path(__file__).resolve().parents[1] / ".env",
        env_file_encoding="utf-8",
        extra="ignore",
        hide_input_in_errors=True,
    )

    environment: Literal["development", "production"] = "development"
    groq_api_key: SecretStr = SecretStr("")
    groq_text_model: str = Field(default="openai/gpt-oss-120b", min_length=1, max_length=150)
    groq_vision_model: str = Field(default="qwen/qwen3.8-27b", min_length=1, max_length=150)
    vision_enabled: bool = False
    firebase_project_id: str = ""
    google_application_credentials: str = ""
    connect_timeout_seconds: float = Field(default=5, gt=0, le=30)
    provider_read_timeout_seconds: float = Field(default=20, gt=0, le=120)
    request_timeout_seconds: float = Field(default=60, gt=0, le=300)
    stream_timeout_seconds: float = Field(default=180, gt=0, le=300)
    auth_timeout_seconds: float = Field(default=10, gt=0, le=30)
    max_auth_workers: int = Field(default=8, ge=1, le=64)
    body_timeout_seconds: float = Field(default=15, gt=0, le=60)
    max_request_bytes: int = Field(default=8_000_000, ge=1024, le=10_000_000)
    max_image_bytes: int = Field(default=5_000_000, ge=1024, le=5_000_000)
    max_image_pixels: int = Field(default=16_000_000, ge=1, le=16_000_000)
    max_history_characters: int = Field(default=48_000, ge=1, le=100_000)
    max_output_tokens: int = Field(default=8192, ge=1, le=32768)
    chat_instructions: str = Field(default=(
        "You are AI Mind, a helpful, accurate and thoughtful assistant. "
        "Answer simple questions concisely; give detailed guidance when requested. "
        "Use short paragraphs, restrained headings and lists only when useful. "
        "Keep tables small and use them only for meaningful comparisons. "
        "Reserve fenced code blocks for source code, commands or literal data. "
        "Never put ordinary advice, study plans or checklists in code fences. "
        "Avoid repetition. Ask a clarifying question only when necessary. "
        "Do not claim to browse or access live data."
    ), min_length=1, max_length=8000)
    rate_limit_backend: Literal["memory", "redis"] = "memory"
    redis_url: SecretStr = SecretStr("")
    requests_per_minute: int = Field(default=10, ge=1, le=1000)
    requests_per_day: int = Field(default=100, ge=1, le=100_000)
    max_concurrent_requests: int = Field(default=2, ge=1, le=20)

    @model_validator(mode="after")
    def safe_configuration(self):
        if self.rate_limit_backend == "redis" and not self.redis_url.get_secret_value():
            raise ValueError("Redis mode requires REDIS_URL")
        if self.environment == "production":
            if self.rate_limit_backend != "redis":
                raise ValueError("Production requires shared Redis quota enforcement")
            if not self.groq_api_key.get_secret_value() or not self.firebase_project_id:
                raise ValueError("Production requires provider and Firebase configuration")
        return self
