"""
Minimal webhook server for LiteLLM budget alerts.
Fires a macOS notification when Anthropic credits are exhausted.
Run alongside the proxy: python alert.py
"""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import subprocess
import sys


def notify(title: str, message: str) -> None:
    subprocess.run([
        "osascript", "-e",
        f'display notification "{message}" with title "{title}" sound name "Basso"'
    ])


class AlertHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            data = json.loads(body)
        except Exception:
            data = {}

        alert_type = data.get("alert_type", "")
        msg = data.get("message", str(data))

        print(f"[alert] {alert_type}: {msg}", flush=True)

        if any(k in alert_type.lower() for k in ("budget", "limit", "credit", "quota")):
            notify("Claude Code — Out of Credits", "Anthropic budget exhausted. Top up to continue.")
        elif alert_type:
            notify(f"LiteLLM: {alert_type}", msg[:120])

        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 4001
    print(f"Alert webhook listening on :{port}")
    HTTPServer(("127.0.0.1", port), AlertHandler).serve_forever()
