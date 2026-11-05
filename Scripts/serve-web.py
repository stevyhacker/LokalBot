#!/usr/bin/env python3
"""Local preview server for web/.

Identical to `python3 -m http.server` except that it refuses to let the
browser cache anything. The stock server sends no cache headers at all, which
lets browsers apply heuristic caching and silently serve a stale styles.css
against freshly edited markup — the page then renders with old CSS and looks
broken in ways the source doesn't explain.

It also answers Range requests, as production does. Without them a browser can
only seek within what it has already buffered, so the home page's demo tabs,
which seek within one film, would jump back to the start.

Usage: Scripts/serve-web.py [port]   (default 8791)
"""
import functools
import http.server
import io
import os
import pathlib
import re
import socketserver
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8791
ROOT = pathlib.Path(__file__).resolve().parent.parent / "web"


class NoCacheHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store, must-revalidate")
        self.send_header("Expires", "0")
        self.send_header("Accept-Ranges", "bytes")
        super().end_headers()

    def send_head(self):
        wanted = re.fullmatch(r"bytes=(\d*)-(\d*)", self.headers.get("Range", ""))
        path = self.translate_path(self.path)
        if not wanted or not os.path.isfile(path):
            return super().send_head()
        size = os.path.getsize(path)
        first, last = wanted.groups()
        if first:
            start, end = int(first), min(int(last), size - 1) if last else size - 1
        elif last:
            start, end = max(size - int(last), 0), size - 1
        else:
            return super().send_head()
        if start > end:
            self.send_error(416)
            return None
        with open(path, "rb") as f:
            f.seek(start)
            body = f.read(end - start + 1)
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        return io.BytesIO(body)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


class Server(socketserver.TCPServer):
    allow_reuse_address = True


if __name__ == "__main__":
    handler = functools.partial(NoCacheHandler, directory=str(ROOT))
    with Server(("127.0.0.1", PORT), handler) as httpd:
        print(f"serving {ROOT} at http://localhost:{PORT} (no-store)")
        httpd.serve_forever()
