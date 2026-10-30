from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


class Message(StrictModel):
    role: Literal["user", "assistant"]
    content: str = Field(min_length=1, max_length=12_000)

    @field_validator("content")
    @classmethod
    def nonblank(cls, value):
        if not value.strip():
            raise ValueError("Message must not be blank")
        return value


class ChatRequest(StrictModel):
    messages: list[Message] = Field(min_length=1, max_length=64)
    mode: Literal["chat", "voice"] = "chat"

    @model_validator(mode="after")
    def last_turn_is_user(self):
        if self.messages[-1].role != "user":
            raise ValueError("The final message must be from the user")
        return self


class ImageRequest(StrictModel):
    image_base64: str = Field(min_length=4, max_length=6_666_668)
    mime_type: Literal["image/jpeg", "image/png", "image/webp"]
    prompt: str = Field(default="Describe this image.", min_length=1, max_length=12_000)
    history: list[Message] = Field(default_factory=list, max_length=63)

    @field_validator("prompt")
    @classmethod
    def nonblank(cls, value):
        if not value.strip():
            raise ValueError("Prompt must not be blank")
        return value


class ImageResponse(StrictModel):
    text: str
    request_id: str


class HealthResponse(StrictModel):
    status: Literal["ok"] = "ok"


class ErrorDetail(StrictModel):
    code: str
    message: str
    retryable: bool
    request_id: str


class ErrorResponse(StrictModel):
    error: ErrorDetail


class DeltaEvent(StrictModel):
    text: str


class DoneEvent(StrictModel):
    finish_reason: str
    request_id: str
