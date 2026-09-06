from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
        elif self.path == "/page":
            host = self.headers["Host"]
            body = f"""<!doctype html>
<html>
  <head>
    <title>Link Extract Fixture</title>
    <meta name="description" content="Fixture page for link extraction">
    <link rel="icon" href="/favicon.ico">
    <link rel="canonical" href="http://{host}/canonical">
  </head>
  <body>fixture</body>
</html>
"""
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(body.encode("utf-8"))
        elif self.path == "/canonical":
            body = """<!doctype html>
<html>
  <head><title>Canonical Fallback</title></head>
  <body>canonical</body>
</html>
"""
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(body.encode("utf-8"))
        elif self.path == "/plain":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"plain text")
        elif self.path == "/favicon.ico":
            self.send_response(200)
            self.send_header("Content-Type", "image/x-icon")
            self.end_headers()
            self.wfile.write(b"icon")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", 8099), Handler).serve_forever()