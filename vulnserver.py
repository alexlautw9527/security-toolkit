#!/usr/bin/env python3
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

HOST = os.environ.get("VULNSERVER_HOST", "127.0.0.1")
PORT = int(os.environ.get("VULNSERVER_PORT", "8901"))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "Apache/2.2.15 (Unix)"

    def version_string(self):
        return self.server_version

    def log_message(self, fmt, *args):
        print(f"[req] {fmt % args}", flush=True)

    def _attach_common(self, extra=None):
        self.send_header("X-Powered-By", "Python/3.14 custom-app/0.9")
        if extra:
            for k, v in extra.items():
                self.send_header(k, v)

    def do_GET(self):
        path, _, qs = self.path.partition("?")
        params = parse_qs(qs)
        if path == "/":
            self._html_page("index", """<h1>Healthcare Portal</h1>
<p>internal triage console</p>
<a href="/echo?msg=hello">echo</a>
&nbsp;<a href="/login">login</a>
&nbsp;<a href="/settings">settings</a>
&nbsp;<a href="/api/flag">api</a>
&nbsp;<a href="/phpinfo.php">phpinfo</a>
&nbsp;<a href="/crash">crash</a>
<!-- TODO: remove debug query before production -->""")
        elif path == "/echo":
            msg = params.get("msg", ["world"])[0]
            self._html_page("echo", f"""<h1>Your message</h1>
<p>{msg}</p>
<script src="http://example.com/tracker.js"></script>
<!-- DEBUG: echoed first 200 chars, query executes with user id=42 -->""", with_cookie=True)
        elif path == "/settings":
            self._html_page("settings", "<h1>Settings</h1><p>patient profile page</p>")
        elif path == "/login":
            self._html_page("login", """<h1>Login</h1>
<form method=post action="/login"><input name=user><input name=pass type=password><input type=submit></form>""")
        elif path == "/phpinfo.php":
            self._html_page("phpinfo", """<h1>phpinfo()</h1>
<table border="1">
<tr><td>PHP Version</td><td class="v">5.6.30</td></tr>
<tr><td>PHP Extension</td><td>build</td></tr>
<tr><td>Loaded modules</td><td>PDO, mysqli, cURL</td></tr>
</table>""")
        elif path == "/api/flag":
            self._json({"flag": "smoke-test-ok", "debug": "true"})
        elif path == "/crash":
            self.send_response(500)
            self._attach_common()
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"Traceback (most recent call last):\n"
                             b'  File "vulnserver.py", line 1, in <module>\n'
                             b"RuntimeError: unhandled exception: order_id=9991\n")
        else:
            self._html_page("notfound", "<h1>404</h1><p>nothing here</p>", status=404)

    def do_POST(self):
        if self.path.split("?", 1)[0] == "/login":
            self.send_response(302)
            self._attach_common({"Location": "/"})
            self.send_header("Set-Cookie", "session=super-secret-token; Path=/")
            self.end_headers()
        else:
            self.send_response(404)
            self._attach_common()
            self.end_headers()

    def _html_page(self, title, body, status=200, with_cookie=False):
        html = ("<!DOCTYPE html>\n<html><head><title>%s</title></head>"
                "<body>%s</body></html>") % (title, body)
        self.send_response(status)
        self._attach_common()
        self.send_header("Content-Type", "text/html; charset=utf-8")
        if with_cookie:
            self.send_header("Set-Cookie", "track=abc123; Path=/")
        self.send_header("Content-Length", str(len(html.encode())))
        self.end_headers()
        self.wfile.write(html.encode())

    def _json(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200)
        self._attach_common({"Access-Control-Allow-Origin": "*"})
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"vulnserver listening on http://{HOST}:{PORT}", flush=True)
    srv.serve_forever()