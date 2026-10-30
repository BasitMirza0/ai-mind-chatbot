from dataclasses import dataclass


@dataclass
class ApiError(Exception):
    status: int
    code: str
    message: str
    retryable: bool = False

    def payload(self, request_id: str) -> dict:
        return {"error": {"code": self.code, "message": self.message,
                          "retryable": self.retryable, "request_id": request_id}}
