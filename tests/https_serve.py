#!/usr/bin/env python3
"""A smart-HTTP git server over TLS (and, beside it, plain HTTP), for
`test_https.sh`. The git protocol itself is the real `git http-backend`, run as
a CGI program; this script only does the transport around it.

    python3 tests/https_serve.py <repos dir> <cert.pem> <key.pem> [user:password]

Prints `ready <tls port> <plain port>` once both listen, then serves until
killed. The TLS side speaks TLS 1.3 only. Routes, on both ports:

    /git/<repo>/...        `git http-backend` over <repos dir>/<repo>, with
                           HTTP Basic auth if `user:password` was given
    /moved/<repo>/...      307 to /git/<repo>/... on the same origin
    /upgrade/<repo>/...    307 to the TLS port's /git/<repo>/... (plain port)
    /downgrade/<repo>/...  307 to the plain port's /git/<repo>/... (TLS port:
                           an https -> http redirect, which a client must not
                           follow)

307 rather than 301/302 because the git requests that follow a redirected
advertisement are POSTs, and only 307/308 keep a method and its body.
"""
import base64
import http.server
import os
import socket
import socketserver
import ssl
import subprocess
import sys
import threading

TLS_PORT = 0
PLAIN_PORT = 0
REPOS = ""
AUTH = None


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, code, body=b"", extra=()):
        self.send_response(code)
        for name, value in extra:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def redirect(self, origin, rest):
        self.reply(307, extra=[("Location", origin + "/git/" + rest)])

    def authorized(self):
        if AUTH is None:
            return True
        want = "Basic " + base64.b64encode(AUTH.encode()).decode()
        return self.headers.get("Authorization", "") == want

    def handle_request(self):
        secure = isinstance(self.connection, ssl.SSLSocket)
        path, _, query = self.path.partition("?")
        kind, _, rest = path.lstrip("/").partition("/")
        suffix = rest + ("?" + query if query else "")
        if kind == "moved":
            return self.reply(307, extra=[("Location", "/git/" + suffix)])
        if kind == "upgrade" and not secure:
            return self.redirect("https://localhost:%d" % TLS_PORT, suffix)
        if kind == "downgrade" and secure:
            return self.redirect("http://localhost:%d" % PLAIN_PORT, suffix)
        if kind != "git":
            return self.reply(404, b"no such route\n")
        if not self.authorized():
            return self.reply(401, extra=[("WWW-Authenticate", 'Basic realm="t"')])
        length = int(self.headers.get("Content-Length", "0") or 0)
        body = self.rfile.read(length) if length else b""
        env = {
            "PATH": os.environ.get("PATH", ""),
            "GIT_PROJECT_ROOT": REPOS,
            "GIT_HTTP_EXPORT_ALL": "1",
            "REQUEST_METHOD": self.command,
            "PATH_INFO": "/" + rest,
            "QUERY_STRING": query,
            "CONTENT_TYPE": self.headers.get("Content-Type", ""),
            "CONTENT_LENGTH": str(len(body)),
            "REMOTE_ADDR": "127.0.0.1",
        }
        backend = os.path.join(subprocess.check_output(["git", "--exec-path"]).decode().strip(), "git-http-backend")
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
        self.reply(status, payload, extra)

    do_GET = handle_request
    do_POST = handle_request


# `localhost` as the client will resolve it: it connects to the first address.
LOCAL = socket.getaddrinfo("localhost", None, type=socket.SOCK_STREAM)[0]


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    address_family = LOCAL[0]
    daemon_threads = True
    allow_reuse_address = True


class TlsServer(Server):
    def get_request(self):
        raw, address = super().get_request()
        try:
            return self.context.wrap_socket(raw, server_side=True), address
        except (ssl.SSLError, OSError):
            raw.close()
            raise

    def handle_error(self, request, client_address):
        pass


def main():
    global TLS_PORT, PLAIN_PORT, REPOS, AUTH
    REPOS = os.path.abspath(sys.argv[1])
    cert, key = sys.argv[2], sys.argv[3]
    AUTH = sys.argv[4] if len(sys.argv) > 4 else None
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.load_cert_chain(cert, key)
    tls = TlsServer((LOCAL[4][0], 0), Handler)
    tls.context = context
    plain = Server((LOCAL[4][0], 0), Handler)
    TLS_PORT = tls.server_address[1]
    PLAIN_PORT = plain.server_address[1]
    threading.Thread(target=plain.serve_forever, daemon=True).start()
    print("ready %d %d" % (TLS_PORT, PLAIN_PORT), flush=True)
    tls.serve_forever()


main()
