import json
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN = int(sys.argv[1])
UPSTREAM = sys.argv[2].rstrip("/")
LOG = sys.argv[3]
lock = threading.Lock()


def record(entry):
    with lock, open(LOG, "a") as f:
        f.write(json.dumps(entry) + "\n")


class Proxy(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def forward(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        headers = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "content-length")}
        request = urllib.request.Request(UPSTREAM + self.path, data=body, method=method, headers=headers)
        started = time.time()
        try:
            with urllib.request.urlopen(request, timeout=1800) as response:
                status, data, reply_headers = response.status, response.read(), response.headers
        except urllib.error.HTTPError as error:
            status, data, reply_headers = error.code, error.read(), error.headers
        elapsed = time.time() - started
        if self.path.endswith("/chat/completions") and body:
            try:
                sent = json.loads(body)
                got = json.loads(data) if status == 200 else {}
                choice = (got.get("choices") or [{}])[0]
                message = choice.get("message") or {}
                record({
                    "at": started, "elapsed": round(elapsed, 2), "status": status,
                    "system": ((sent.get("messages") or [{}])[0].get("content") or "")[:80],
                    "max_tokens": sent.get("max_tokens"),
                    "thinking_budget_tokens": sent.get("thinking_budget_tokens"),
                    "chat_template_kwargs": sent.get("chat_template_kwargs"),
                    "schema": "response_format" in sent,
                    "finish": choice.get("finish_reason"),
                    "usage": got.get("usage"),
                    "timings": got.get("timings"),
                    "reasoning_chars": len(message.get("reasoning_content") or ""),
                    "content_chars": len(message.get("content") or ""),
                    "error": None if status == 200 else data[:300].decode("utf-8", "replace"),
                })
            except Exception as exc:
                record({"at": started, "proxy_error": repr(exc)})
        self.send_response(status)
        for key, value in reply_headers.items():
            if key.lower() not in ("transfer-encoding", "content-length", "connection"):
                self.send_header(key, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.forward("GET")

    def do_POST(self):
        self.forward("POST")


ThreadingHTTPServer(("127.0.0.1", LISTEN), Proxy).serve_forever()
