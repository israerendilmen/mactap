"""Local HTTP server: static GUI, a Server-Sent Events stream and a small JSON command API.

It listens on 127.0.0.1 only. Because the API can set shell commands for zone actions, every
POST must carry the per-run token embedded in the page (a custom header also forces a CORS
preflight that other sites cannot pass), and the Host header must be local (DNS rebinding).
"""

import json
import secrets
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

STATIC = Path(__file__).parent / "static"
TOKEN = secrets.token_urlsafe(24)
TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
         ".css": "text/css; charset=utf-8"}
MAX_BODY = 1 << 20  # commands are tiny; refuse anything bigger
# The page holds the token, so it must not be framed by another site (clickjacking).
SECURITY_HEADERS = {
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Content-Security-Policy": "default-src 'self'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
    "Referrer-Policy": "no-referrer",
}


def _round(rows, nd=3):
    return [[round(v, nd) for v in r] for r in rows]


class Handler(BaseHTTPRequestHandler):
    app = None
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _local(self):
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0]
        return host in ("127.0.0.1", "localhost", "[::1]")

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for k, v in SECURITY_HEADERS.items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self._local():
            return self._send(403, {"error": "forbidden host"})
        path = self.path.split("?", 1)[0]
        if path == "/":
            html = (STATIC / "index.html").read_text().replace("{{TOKEN}}", TOKEN)
            return self._send(200, html.encode(), TYPES[".html"])
        if path.startswith("/static/"):
            f = (STATIC / path[len("/static/"):]).resolve()
            if f.parent == STATIC.resolve() and f.suffix in TYPES and f.exists():
                return self._send(200, f.read_bytes(), TYPES[f.suffix])
        if path == "/stream":
            return self._stream()
        if path == "/api/state":
            return self._send(200, {"status": self.app.status(), "report": self.app.report})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self._local() or not secrets.compare_digest(self.headers.get("X-Token") or "", TOKEN):
            self.close_connection = True  # the unread body would corrupt the next request on this connection
            return self._send(403, {"error": "forbidden"})
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self.close_connection = True
            return self._send(400, {"error": "bad Content-Length"})
        if not 0 <= n <= MAX_BODY:
            self.close_connection = True
            return self._send(413, {"error": "body too large"})
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except (ValueError, UnicodeDecodeError):
            return self._send(400, {"error": "body must be JSON"})
        if not isinstance(body, dict):
            return self._send(400, {"error": "body must be a JSON object"})
        app = self.app
        cmd = self.path.split("?", 1)[0].removeprefix("/api/")
        handlers = {
            "config": lambda: app.set_config(body),
            "calibrate": lambda: app.calibrate_start(body),
            "negatives": lambda: app.negatives_start(body),
            "stop": app.stop,
            "undo": app.undo,
            "clear": app.clear,
            "delete_label": lambda: app.delete_label(str(body["label"])),
            "train": app.train,
        }
        if cmd not in handlers:
            return self._send(404, {"error": "unknown command"})
        try:
            handlers[cmd]()
        except (ValueError, KeyError) as e:
            return self._send(400, {"error": str(e)})
        except Exception as e:
            traceback.print_exc()
            return self._send(500, {"error": f"{type(e).__name__}: {e}"})
        self._send(200, {"status": app.status(), "report": app.report})

    def _stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        for k, v in SECURITY_HEADERS.items():
            self.send_header(k, v)
        self.end_headers()
        self.close_connection = True
        app = self.app
        seq = app.detector.seq - 1600
        last_ev = max((e["id"] for e in app.events_since(0)), default=0) - 15
        last_status = 0.0

        def send(event, payload):
            self.wfile.write(f"event: {event}\ndata: {json.dumps(payload)}\n\n".encode())

        try:
            while True:
                rows = app.detector.rows_since(seq)
                if rows:
                    seq = rows[-1][0]
                    send("samples", {"rows": _round([r[1:] for r in rows], 4),
                                     "thr": round(app.detector.threshold, 3)})
                for ev in app.events_since(last_ev):
                    last_ev = ev["id"]
                    send("tap", ev)
                if time.monotonic() - last_status > 0.25:
                    last_status = time.monotonic()
                    send("status", app.status())
                self.wfile.flush()
                time.sleep(1 / 30)
        except (BrokenPipeError, ConnectionResetError):
            return


def serve(app, port):
    Handler.app = app
    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    httpd.daemon_threads = True
    return httpd
