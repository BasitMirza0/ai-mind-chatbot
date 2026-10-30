import base64
import binascii
import io
import warnings

from PIL import Image, UnidentifiedImageError

from .config import Settings
from .errors import ApiError
from .schemas import ImageRequest


def validated_image(payload: ImageRequest, settings: Settings) -> bytes:
    if len(payload.image_base64) > ((settings.max_image_bytes + 2) // 3) * 4:
        raise ApiError(413, "image_too_large", "Image exceeds the configured size limit.")
    try:
        raw = base64.b64decode(payload.image_base64, validate=True)
    except (binascii.Error, ValueError):
        raise ApiError(422, "invalid_image", "Image must contain valid base64 data.") from None
    if not raw or len(raw) > settings.max_image_bytes:
        raise ApiError(413, "image_too_large", "Image exceeds the configured size limit.")
    formats = {"image/jpeg": "JPEG", "image/png": "PNG", "image/webp": "WEBP"}
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(raw)) as image:
                if image.format != formats[payload.mime_type]:
                    raise ValueError("Format mismatch")
                if image.width * image.height > settings.max_image_pixels or getattr(image, "n_frames", 1) != 1:
                    raise ValueError("Dimensions or animation not supported")
                image.verify()
    except (UnidentifiedImageError, ValueError, OSError,
            Image.DecompressionBombError, Image.DecompressionBombWarning):
        raise ApiError(422, "invalid_image", "Use a valid, non-animated JPEG, PNG, or WebP within the pixel limit.") from None
    return raw
