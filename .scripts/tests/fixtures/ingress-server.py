import hmac
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


TOKEN = Path("/fixture/secrets/token").read_text().rstrip("\n")
HEADER = "X-Internal-Ingress-Token"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        token = self.headers.get_all(HEADER) or []
        if self.path == "/oauth2/auth":
            if token or self.headers.get("Cookie") != "_oauth2_proxy=valid":
                self.send_response(401)
                self.end_headers()
                return
            self.send_response(202)
            self.send_header("X-Auth-Request-User", "test-user")
            self.send_header("X-Auth-Request-Issuer", "https://accounts.google.com")
            self.send_header("X-Auth-Request-Email", "test@example.com")
            self.send_header("X-Auth-Request-Email-Verified", "true")
            self.end_headers()
            return
        if self.path == "/graphql" and (
            len(token) != 1 or not hmac.compare_digest(token[0], TOKEN)
        ):
            self.send_response(403)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(
            json.dumps(
                {
                    "ingress": bool(token),
                    "user": self.headers.get("X-Auth-Request-User"),
                    "authorization": self.headers.get("Authorization"),
                }
            ).encode()
        )

    def log_message(self, *_args):
        pass


HTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
