"""Content-free lifecycle records. Never pass exception bodies or user data."""
import json
import logging
import re

logger = logging.getLogger("aimind.stream")
logger.setLevel(logging.INFO)
# Uvicorn configures its own named loggers, not the root logger. Install a
# dedicated content-free handler so these records also exist outside pytest.
if not logger.handlers:
    handler = logging.StreamHandler()
    handler.setFormatter(logging.Formatter("%(message)s"))
    logger.addHandler(handler)


def trace(request_id: str, state: str, **fields):
    record = {"request_id": request_id if re.fullmatch(r"[a-f0-9]{32}", request_id) else "unassigned",
              "state": state}
    for key in ("category", "finish_reason", "characters", "max_output_tokens", "terminal", "status", "attempt", "elapsed_ms"):
        value = fields.get(key)
        if isinstance(value, (bool, int)) or (isinstance(value, str) and re.fullmatch(r"[a-z_]{1,48}", value)):
            record[key] = value
    logger.info("ai_mind_stream %s", json.dumps(record, separators=(",", ":")))
