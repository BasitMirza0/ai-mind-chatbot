"""Bounded SSE framing, including fragmented UTF-8 and multiline data."""
from collections.abc import AsyncIterable, AsyncIterator


async def sse_data(chunks: AsyncIterable[bytes], limit: int = 65_536) -> AsyncIterator[str]:
    line = bytearray()
    data: list[str] = []
    event_bytes = 0
    previous_cr = False
    async for chunk in chunks:
        for byte in chunk:
            if byte == 10 and previous_cr:
                previous_cr = False
                continue
            previous_cr = byte == 13
            if byte not in (10, 13):
                line.append(byte)
                event_bytes += 1
                if event_bytes > limit:
                    raise ValueError("Oversized SSE event")
                continue
            value = line.decode("utf-8")
            line.clear()
            if not value:
                if data:
                    yield "\n".join(data)
                data.clear()
                event_bytes = 0
            elif value.startswith("data:"):
                field = value[5:]
                data.append(field[1:] if field.startswith(" ") else field)
            # Comments and unknown fields are ignored but remain size-bounded.
    # An event without its final blank line is incomplete; never dispatch it.
