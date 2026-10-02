#!/usr/bin/env python3
"""A stand-in OpenAI-compatible /v1/chat/completions server for end-to-end checks.

Echoes the user's text back tagged, so a session log proves the request reached this
process and the reply travelled the whole pipeline. Records every request to a JSONL file.
"""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18080
LOG = sys.argv[2] if len(sys.argv) > 2 else "/tmp/mock_chat_requests.jsonl"

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization"), "body": body}, ensure_ascii=False) + "\n")
        if self.path.rstrip("/") != "/v1/chat/completions":
            self.send_response(404); self.end_headers(); self.wfile.write(b'{"error":{"message":"not found"}}'); return
        user = next((m["content"] for m in body.get("messages", []) if m.get("role") == "user"), "")
        reply = {"id": "mock", "object": "chat.completion", "model": body.get("model"),
                 "choices": [{"index": 0, "message": {"role": "assistant", "content": "<think>x</think>「译:" + user + "」"}, "finish_reason": "stop"}]}
        data = json.dumps(reply, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

if __name__ == "__main__":
    print(f"mock chat server on {PORT}, log {LOG}", flush=True)
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
