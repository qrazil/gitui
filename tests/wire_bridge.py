"""A real git service behind a TCP socket, for test_wire.sh.

    python3 wire_bridge.py <upload-pack|receive-pack> <repo> <port-file>

Binds 127.0.0.1 on a free port, writes the port number to <port-file>, and for
each connection runs `git <service> <repo>` (the stateful, non-stateless-rpc
form: the same process an ssh server would run for `git-upload-pack <repo>`),
pumping bytes both ways with no framing of its own. One connection at a time.
It exits when its parent process does, so a test that dies leaves nothing
behind. The service inherits the environment, so GIT_TRACE_PACKET can be set
to watch the client's packets from the server's side.
"""

import os
import socket
import subprocess
import sys
import threading

service, repo, port_file = sys.argv[1:4]
parent = os.getppid()

listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", 0))
listener.listen(8)
listener.settimeout(1.0)
with open(port_file + ".tmp", "w") as f:
    f.write(str(listener.getsockname()[1]))
os.rename(port_file + ".tmp", port_file)


def to_service(conn, stdin):
    try:
        while True:
            data = conn.recv(65536)
            if not data:
                break
            stdin.write(data)
            stdin.flush()
    except OSError:
        pass
    try:
        stdin.close()
    except OSError:
        pass


def serve(conn):
    proc = subprocess.Popen(
        ["git", service, repo],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    pump = threading.Thread(target=to_service, args=(conn, proc.stdin), daemon=True)
    pump.start()
    try:
        while True:
            data = os.read(proc.stdout.fileno(), 65536)
            if not data:
                break
            conn.sendall(data)
    except OSError:
        pass
    proc.wait()
    try:
        conn.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    conn.close()


while os.getppid() == parent:
    try:
        conn, _ = listener.accept()
    except socket.timeout:
        continue
    serve(conn)
