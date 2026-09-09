#!/usr/bin/env python3
"""One page; its subresource either exists or 404s, chosen by the mode."""
import http.server, socketserver, sys

MODE = sys.argv[2] if len(sys.argv) > 2 else "missing"
PNG = bytes.fromhex('89504e470d0a1a0a0000000d4948445200000001000000010806000000'
                    '1f15c4890000000a49444154789c6300010000050001'
                    '0d0a2db40000000049454e44ae426082')

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_GET(self):
        if self.path.startswith("/pic"):
            if MODE == "missing":
                body = b"not here"
                self.send_response(404)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_response(200)
                self.send_header("Content-Type", "image/png")
                self.send_header("Content-Length", str(len(PNG)))
                self.end_headers()
                self.wfile.write(PNG)
            return
        body = b'<!doctype html><meta charset=utf-8><title>sub</title><body style="font:14px monospace;padding:6px"><p>subresource: ' + MODE.encode() + b'</p><img src="/pic.png" width="40" height="40">'
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass

class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True; allow_reuse_address = True

with Server(("0.0.0.0", int(sys.argv[1])), Handler) as httpd:
    httpd.serve_forever()
