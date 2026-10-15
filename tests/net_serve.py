#!/usr/bin/env python3
"""A smart-HTTP git server on localhost for the network oracle tests: the
real `git http-backend` as a CGI program (protocol v0 and v2, push enabled),
optional HTTP Basic auth, and a request log.

    python3 tests/net_serve.py <repos dir> <log file> [user:password]

Prints `ready <port>` once listening. Every request is one log line:
`<METHOD> <path> proto=<Git-Protocol> auth=<yes|no> status=<code>`; the
credentials themselves are never logged. `/git/<repo>/...` serves
<repos dir>/<repo>.
"""
import base64
import http.server
import os
import socketserver
import subprocess
import sys
import threading

REPOS = os.path.abspath(sys.argv[1])
LOG = sys.argv[2]
AUTH = sys.argv[3] if len(sys.argv) > 3 else None
LOCK = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def note(self, status):
        line = "%s %s proto=%s auth=%s status=%d\n" % (
            self.command, self.path, self.headers.get("Git-Protocol", "-"),
            "yes" if self.headers.get("Authorization") else "no", status)
        with LOCK:
            with open(LOG, "a") as f:
                f.write(line)

    def reply(self, code, body=b"", extra=(), chunked=False):
        self.note(code)
        self.send_response(code)
        for name, value in extra:
            self.send_header(name, value)
        self.send_header("Connection", "close")
        if chunked:
            # like a real git server: no Content-Length, chunks of 64 KiB
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for i in range(0, len(body), 65536):
                piece = body[i:i + 65536]
                self.wfile.write(b"%x\r\n" % len(piece) + piece + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
            return
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_request(self):
        path, _, query = self.path.partition("?")
        kind, _, rest = path.lstrip("/").partition("/")
        length = int(self.headers.get("Content-Length", "0") or 0)
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            body = b""
            while True:
                size = int(self.rfile.readline().strip() or b"0", 16)
                if size == 0:
                    self.rfile.readline()
                    break
                body += self.rfile.read(size)
                self.rfile.readline()
        else:
            body = self.rfile.read(length) if length else b""
        if kind != "git":
            return self.reply(404, b"no such route\n")
        if AUTH is not None:
            want = "Basic " + base64.b64encode(AUTH.encode()).decode()
            if self.headers.get("Authorization", "") != want:
                return self.reply(401, extra=[("WWW-Authenticate", 'Basic realm="t"')])
        if body[:2] == b"\x1f\x8b":
            import gzip
            body = gzip.decompress(body)
        backend = os.environ.get("NET_BACKEND") or os.path.join(
            subprocess.run(["git", "--exec-path"], capture_output=True, text=True).stdout.strip(),
            "git-http-backend")
        exec_dir = os.path.dirname(backend)
        env = {
            "PATH": exec_dir + ":/usr/bin:/bin:/usr/local/bin",
            "GIT_EXEC_PATH": exec_dir,
            "GIT_PROJECT_ROOT": REPOS,
            "GIT_HTTP_EXPORT_ALL": "1",
            "REQUEST_METHOD": self.command,
            "PATH_INFO": "/" + rest,
            "QUERY_STRING": query,
            "CONTENT_TYPE": self.headers.get("Content-Type", ""),
            "CONTENT_LENGTH": str(len(body)),
            "REMOTE_ADDR": "127.0.0.1",
            "REMOTE_USER": "tester",
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "http.receivepack",
            "GIT_CONFIG_VALUE_0": "true",
        }
        if self.headers.get("Git-Protocol"):
            env["GIT_PROTOCOL"] = self.headers["Git-Protocol"]
        done = subprocess.run([backend], input=body, env=env, capture_output=True)
        head, separator, payload = done.stdout.partition(b"\r\n\r\n")
        if not separator:
            head, separator, payload = done.stdout.partition(b"\n\n")
        status = 200
        extra = []
        for line in head.decode("latin-1").splitlines():
            name, _, value = line.partition(":")
            if name.lower() == "status":
                status = int(value.split()[0])
            elif name.lower() not in ("content-length", "connection"):
                extra.append((name, value.strip()))
        self.reply(status, payload, extra, chunked=(self.command == "POST"))

    do_GET = handle_request
    do_POST = handle_request


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


server = Server(("127.0.0.1", 0), Handler)
print("ready %d" % server.server_address[1], flush=True)
server.serve_forever()
