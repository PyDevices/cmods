"""Small requests-compatible facade over the builtin Fetch bridge."""

import io
import json

import _wasm_bridge


class Response:
    def __init__(self, status_code, content, url):
        self.status_code = status_code
        self.content = content
        self.url = url
        self.raw = io.BytesIO(content)

    @property
    def text(self):
        return self.content.decode()

    def json(self):
        return json.loads(self.content)

    def close(self):
        self.raw.close()


def get(url, **_kwargs):
    last_error = None
    for attempt in range(3):
        try:
            status, content, final_url = _wasm_bridge.http_get(url)
            return Response(status, content, final_url)
        except OSError as error:
            last_error = error
            if attempt < 2:
                _wasm_bridge.sleep_ms(100 * (attempt + 1))
    raise last_error
