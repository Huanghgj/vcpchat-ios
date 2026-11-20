"""Loopback-only, gated SSE fixture for the simulator's system URLSession daemon."""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

next_frame, finish = threading.Event(), threading.Event()


class Reply(BaseHTTPRequestHandler):
    count = 0

    def do_GET(self):
        if self.path == "/next":
            next_frame.set()
        elif self.path == "/finish":
            finish.set()
        elif self.path != "/count":
            self.send_error(404)
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(str(Reply.count).encode())

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path != "/v1/chat/completions" or body.get("stream") is not True:
            self.send_error(400)
            return
        Reply.count += 1
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        for content, reasoning, gate in [("首段", "思", next_frame), ("补齐", "考", finish)]:
            payload = {"choices": [{"delta": {"content": content, "reasoning_content": reasoning}}]}
            self.wfile.write(("data: " + json.dumps(payload, ensure_ascii=False) + "\n\n").encode())
            self.wfile.flush()
            if not gate.wait(40):
                return
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


with ThreadingHTTPServer(("127.0.0.1", 0), Reply) as server:
    Path(sys.argv[1]).write_text(str(server.server_port))
    server.serve_forever()
