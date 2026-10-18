#!/usr/bin/env python3
"""Serve a Godot web export locally with the cross-origin-isolation headers
threaded builds need, so a browser test is possible outside itch.io.

    python3 tools/serve_web.py [dir] [port]

Adds `Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp` (plus the correct wasm MIME type)
and serves `dir` (default: the current directory) at http://127.0.0.1:port/.
"""

import http.server
import socketserver
import sys

DIRECTORY = sys.argv[1] if len(sys.argv) > 1 else "."
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8060


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = dict(http.server.SimpleHTTPRequestHandler.extensions_map)
    extensions_map[".wasm"] = "application/wasm"
    extensions_map[".pck"] = "application/octet-stream"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    with Server(("127.0.0.1", PORT), Handler) as httpd:
        print(f"serving {DIRECTORY} on http://127.0.0.1:{PORT}/ (COOP/COEP set)")
        httpd.serve_forever()
