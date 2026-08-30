#!/usr/bin/env python3
import io
import sys
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from PIL import Image

PORT = 8091
MAX_DIMENSION_DEFAULT = 900
JPEG_QUALITY = 72
CACHE_LIMIT = 500

_cache = {}
_cache_order = []


def fetch_original(url):
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(request, timeout=15) as response:
        return response.read(), response.headers.get("Content-Type", "")


def shrink(data, max_dimension):
    image = Image.open(io.BytesIO(data))
    image = image.convert("RGB")
    width, height = image.size
    scale = min(1.0, max_dimension / max(width, height))
    if scale < 1.0:
        image = image.resize((max(1, int(width * scale)), max(1, int(height * scale))), Image.LANCZOS)
    out = io.BytesIO()
    image.save(out, format="JPEG", quality=JPEG_QUALITY, optimize=True)
    return out.getvalue()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        sys.stderr.write("[image-proxy] " + (format % args) + "\n")

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/img":
            self.send_response(404)
            self.end_headers()
            return
        query = urllib.parse.parse_qs(parsed.query)
        target = query.get("u", [None])[0]
        if not target:
            self.send_response(400)
            self.end_headers()
            return
        max_dimension = int(query.get("w", [MAX_DIMENSION_DEFAULT])[0])

        cache_key = (target, max_dimension)
        cached = _cache.get(cache_key)
        if cached:
            self.respond_jpeg(cached)
            self.log_message("cache hit %s", target[:80])
            return

        started = time.time()
        try:
            original, _content_type = fetch_original(target)
            shrunk = shrink(original, max_dimension)
        except Exception as error:
            self.log_message("failed %s: %s", target[:80], error)
            try:
                original, content_type = fetch_original(target)
                self.respond(original, content_type or "application/octet-stream")
            except Exception as fallback_error:
                self.log_message("fallback failed %s: %s", target[:80], fallback_error)
                self.send_response(502)
                self.end_headers()
            return

        _cache[cache_key] = shrunk
        _cache_order.append(cache_key)
        if len(_cache_order) > CACHE_LIMIT:
            oldest = _cache_order.pop(0)
            _cache.pop(oldest, None)

        elapsed = time.time() - started
        self.log_message("%s %dB -> %dB in %.2fs", target[:80], len(original), len(shrunk), elapsed)
        self.respond_jpeg(shrunk)

    def respond_jpeg(self, data):
        self.respond(data, "image/jpeg")

    def respond(self, data, content_type):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "public, max-age=86400")
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"[image-proxy] listening on 0.0.0.0:{PORT}")
    server.serve_forever()
