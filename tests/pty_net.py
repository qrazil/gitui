#!/usr/bin/env python3
"""mgit's network actions and remote-branch switcher under a real pty, against
`tests/net_serve.py` (real `git http-backend` with HTTP Basic auth) on
localhost; real git is the oracle.

    python3 tests/pty_net.py <mgit-binary> <scratch-dir>

Covers: `F f` fetch, `F g` pull, `F r` pull --rebase, `P g` push (each hands the
terminal to the library's own command and comes back), a wrong password shown
as an error without the secret appearing anywhere on screen, and `b r`
checking out a remote branch with a tracking branch created. Credentials come
from a GIT_ASKPASS script, which is the library's own credential flow. The
exit code is the number of failures.
"""
import os
import shutil
import subprocess
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pty_e2e  # noqa: E402
from pty_e2e import GIT_ENV, CLIENT_ENV, Session, fail, git, ok  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
USER = "netuser"
SECRET = "s3cr3t-pw-Zq91"


def wait_for(session, needle, seconds=20.0):
    deadline = time.time() + seconds
    while time.time() < deadline:
        session.drain(0.3)
        if needle in session.text():
            return True
    return needle in session.text()


def act(session, keys, needle, seconds=20.0):
    """Send `keys`, then read the raw terminal stream until `needle` shows up
    in what came after them (the emulated screen keeps stale text across the
    handoff to and from the normal screen, so a screen match could be old)."""
    raw = session.send(keys)
    deadline = time.time() + seconds
    while needle.encode() not in raw and time.time() < deadline:
        raw += session.drain(0.3)
    return raw


def check(name, condition, detail=""):
    if condition:
        ok(name)
    else:
        fail(name, detail)


def commit(repo, name, text, message):
    with open(os.path.join(repo, name), "w") as f:
        f.write(text)
    git(repo, "add", "-A", env=GIT_ENV)
    git(repo, "commit", "-q", "-m", message, env=GIT_ENV)


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    binpath = os.path.abspath(sys.argv[1])
    root = os.path.abspath(sys.argv[2])
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(os.path.join(root, "repos"))
    bare = os.path.join(root, "repos", "r.git")
    seed = os.path.join(root, "seed")
    subprocess.run(["git", "init", "-q", "-b", "main", seed], check=True)
    commit(seed, "a.txt", "one\n", "first")
    subprocess.run(["git", "clone", "-q", "--bare", seed, bare], check=True)
    subprocess.run(["git", "-C", bare, "config", "http.receivepack", "true"], check=True)

    log = os.path.join(root, "server.log")
    ready = os.path.join(root, "ready")
    with open(ready, "w") as out:
        server = subprocess.Popen([sys.executable, os.path.join(HERE, "net_serve.py"), os.path.join(root, "repos"), log, "%s:%s" % (USER, SECRET)], stdout=out)
    try:
        port = ""
        for _ in range(100):
            text = open(ready).read()
            if text.startswith("ready"):
                port = text.split()[1]
                break
            time.sleep(0.1)
        if not port:
            fail("server started", "no ready line")
            return 1
        url = "http://127.0.0.1:%s/git/r.git" % port
        run(binpath, root, bare, seed, url)
    finally:
        server.kill()
        server.wait()
    return pty_e2e.failures


def run(binpath, root, bare, seed, url):
    askpass = os.path.join(root, "askpass.sh")
    with open(askpass, "w") as f:
        f.write('#!/bin/sh\ncase "$1" in\n  Username*) echo "%s" ;;\n  *) echo "$MGIT_TEST_PW" ;;\nesac\n' % USER)
    os.chmod(askpass, 0o755)
    env = dict(CLIENT_ENV)
    env["GIT_ASKPASS"] = askpass
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["MGIT_TEST_PW"] = SECRET
    for key in ("credential.helper",):
        env.pop(key, None)
    env["GIT_CONFIG_GLOBAL"] = os.devnull
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    env["HOME"] = root

    client = os.path.join(root, "client")
    other = os.path.join(root, "other")
    subprocess.run(["git", "clone", "-q", bare, client], check=True, env=GIT_ENV)
    subprocess.run(["git", "clone", "-q", bare, other], check=True, env=GIT_ENV)
    git(client, "remote", "set-url", "origin", url)
    git(other, "remote", "set-url", "origin", url)
    subprocess.run(["git", "-C", client, "config", "gc.auto", "0"], check=True)

    def server_head(branch="main"):
        return git(bare, "rev-parse", "refs/heads/" + branch)[0]

    # --- fetch -------------------------------------------------------------
    commit(seed, "b.txt", "two\n", "second")
    git(seed, "push", "-q", bare, "main", env=GIT_ENV)
    want = server_head()
    s = Session(binpath, client, env=env)
    s.send("F")
    check("fetch: the pull menu offers f", "fetch" in s.text(), s.text())
    raw = act(s, "f", "press Enter")
    check("fetch: the terminal is handed over and the command named", b"running 'fetch'" in raw, repr(raw[-300:]))
    check("fetch: no secret on screen", SECRET.encode() not in raw and SECRET not in s.text())
    s.send("\n")
    check("fetch: back in the client with a status line", wait_for(s, "fetch: done"), s.text())
    got = git(client, "rev-parse", "refs/remotes/origin/main")[0]
    check("fetch: origin/main moved to the server's commit", got == want, "%s != %s" % (got, want))
    check("fetch: the working branch did not move", git(client, "rev-parse", "HEAD")[0] != want)

    # --- pull ---------------------------------------------------------------
    s.send("F")
    raw = act(s, "g", "press Enter")
    check("pull: terminal handed over", b"press Enter" in raw, repr(raw[-300:]))
    s.send("\n")
    check("pull: status line", wait_for(s, "merged origin/main"), s.text())
    check("pull: HEAD fast-forwarded", git(client, "rev-parse", "HEAD")[0] == want)

    # --- pull --rebase over a local commit -----------------------------------
    commit(client, "local.txt", "local\n", "local work")
    commit(seed, "c.txt", "three\n", "third")
    git(seed, "push", "-q", bare, "main", env=GIT_ENV)
    s.send("F")
    raw = act(s, "r", "press Enter")
    check("pull --rebase: fetch on the terminal first", b"running 'fetch'" in raw, repr(raw[-300:]))
    s.send("\n")
    check("pull --rebase: rebased onto the fetched upstream", wait_for(s, "rebase"), s.text())
    log_out = git(client, "log", "--format=%s")[0].split("\n")
    check("pull --rebase: local commit sits on the server's", log_out[:2] == ["local work", "third"], str(log_out))

    # --- push ---------------------------------------------------------------
    s.send("P")
    raw = act(s, "g", "press Enter")
    check("push: terminal handed over", b"running 'push'" in raw, repr(raw[-300:]))
    s.send("\n")
    check("push: status line", wait_for(s, "push: done"), s.text())
    check("push: the server has the local commit", server_head() == git(client, "rev-parse", "HEAD")[0])

    # --- a remote branch with tracking creation -------------------------------
    git(seed, "checkout", "-q", "-b", "feature/x", env=GIT_ENV)
    commit(seed, "x.txt", "x\n", "feature work")
    git(seed, "push", "-q", bare, "feature/x", env=GIT_ENV)
    s.send("F")
    act(s, "f", "press Enter")
    s.send("\n")
    wait_for(s, "fetch: done")
    s.send("b")
    s.send("r")
    check("remote branch: the picker lists origin/feature/x", wait_for(s, "origin/feature/x"), s.text())
    s.send("\r")
    check("remote branch: status line", wait_for(s, "tracking origin/feature/x"), s.text())
    check("remote branch: on feature/x", git(client, "symbolic-ref", "--short", "HEAD")[0] == "feature/x")
    check("remote branch: branch.feature/x.remote", git(client, "config", "branch.feature/x.remote")[0] == "origin")
    check("remote branch: branch.feature/x.merge", git(client, "config", "branch.feature/x.merge")[0] == "refs/heads/feature/x")
    check("remote branch: the file is checked out", os.path.exists(os.path.join(client, "x.txt")))
    check("remote branch: fsck clean", git(client, "fsck", "--strict")[2] == 0)
    s.quit()

    # --- a wrong password: the error is shown, the secret is not --------------
    env_bad = dict(env)
    env_bad["MGIT_TEST_PW"] = "wrong-" + SECRET
    s = Session(binpath, client, env=env_bad)
    s.send("F")
    raw = act(s, "f", "press Enter")
    check("bad password: terminal handed over", b"running 'fetch'" in raw, repr(raw[-300:]))
    shown = s.text()
    check("bad password: neither password on screen", SECRET.encode() not in raw and SECRET not in shown, shown)
    s.send("\n")
    check("bad password: the failure is in the status line", wait_for(s, "failed"), s.text())
    check("bad password: still no secret", SECRET not in s.text())
    s.quit()


if __name__ == "__main__":
    sys.exit(main())
