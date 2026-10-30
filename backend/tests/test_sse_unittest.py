"""Dependency-free parser checks; also collected by the full pytest suite."""
import unittest

from app.sse import sse_data


async def chunks(parts):
    for part in parts:
        yield part


class SseFramingTests(unittest.IsolatedAsyncioTestCase):
    async def test_fragmented_unicode_crlf_and_multiline_data(self):
        wire = ': heartbeat\r\nevent: delta\r\ndata: {"text":\r\ndata: "سلام"}\r\n\r\ndata: [DONE]\r\n\r\n'.encode()
        result = [item async for item in sse_data(chunks(bytes([b]) for b in wire))]
        self.assertEqual(result, ['{"text":\n"سلام"}', '[DONE]'])

    async def test_cr_only_comments_and_unknown_fields(self):
        result = [item async for item in sse_data(chunks([b': hi\rid: x\r\rdata: a\r\rdata: b\r\r']))]
        self.assertEqual(result, ['a', 'b'])

    async def test_unterminated_final_event_is_not_dispatched(self):
        for wire in (b'data: [DONE]', b'data: [DONE]\n'):
            self.assertEqual([item async for item in sse_data(chunks([wire]))], [])

    async def test_no_newline_is_bounded_while_buffering(self):
        with self.assertRaises(ValueError):
            _ = [item async for item in sse_data(chunks([b'data: ' + b'x' * 65_536]))]

    async def test_many_small_data_lines_cannot_evade_event_bound(self):
        with self.assertRaises(ValueError):
            _ = [item async for item in sse_data(chunks([b'data: x\n' * 10_000]))]

    async def test_invalid_utf8_is_rejected(self):
        with self.assertRaises(UnicodeDecodeError):
            _ = [item async for item in sse_data(chunks([b'data: \xff\n\n']))]


if __name__ == '__main__':
    unittest.main()
