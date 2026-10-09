#!/usr/bin/env python3
"""The interactive client's ssh remotes, driven under a real pty against a
disposable sshd (set up by `test_ssh.sh`, which also supplies the environment:
HOME, GITUI_SSH_IDENTITY, GITUI_SSH_KNOWN_HOSTS). Reuses `pty_e2e.py`'s
terminal emulator and session driver; real git is the oracle throughout.

    python3 tests/pty_ssh.py <gitui> <scratch-dir> <bare-repo> <ssh-url> \
        <host-fingerprint> <other-host-key.pub> <port>

`<bare-repo>` is the repository `<ssh-url>` names, reachable here by path so
the other side of each exchange can be made with plain git. The exit code is
the number of failures.
"""
import os
import shutil
import subprocess
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pty_e2e  # noqa: E402
from pty_e2e import GIT_ENV, Session, fail, git, ok  # noqa: E402


def wait_for(session, needle, seconds=15.0):
    """Drain the pty until `needle` is on the screen, or time runs out."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        session.drain(0.3)
        if needle in session.text():
            return True
    return needle in session.text()


def commit(repo, name, text, message):
    with open(os.path.join(repo, name), "w") as f:
        f.write(text)
    git(repo, "add", "-A", env=GIT_ENV)
    git(repo, "commit", "-q", "-m", message, env=GIT_ENV)


def main():
    if len(sys.argv) != 8:
        print(__doc__, file=sys.stderr)
        return 2
    binpath, root, bare, url, fingerprint, other_pub, port = sys.argv[1:8]
    binpath = os.path.abspath(binpath)
    root = os.path.abspath(root)
    known_hosts = os.environ["GITUI_SSH_KNOWN_HOSTS"]
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(root)
    shutil.rmtree(os.path.dirname(known_hosts), ignore_errors=True)

    client = os.path.join(root, "client")
    other = os.path.join(root, "other")
    subprocess.run(["git", "clone", "-q", bare, client], check=True, env=GIT_ENV)
    subprocess.run(["git", "clone", "-q", bare, other], check=True, env=GIT_ENV)
    git(client, "remote", "set-url", "origin", url)
    commit(other, "up1.txt", "from upstream\n", "upstream 1")
    git(other, "push", "-q", "origin", "main", env=GIT_ENV)
    old_head, _, _ = git(client, "rev-parse", "HEAD")
    upstream, _, _ = git(other, "rev-parse", "HEAD")

    # --- pull from a host that is not in known_hosts: the confirm overlay ------
    s = Session(binpath, client)
    s.send("F")
    s.send("p")
    if wait_for(s, "not known"):
        ok("ssh pull: an unknown host raises the confirm overlay")
    else:
        fail("ssh pull: an unknown host raises the confirm overlay", s.text())
    screen = s.text()
    if fingerprint in screen:
        ok("ssh pull: the overlay shows the server's real fingerprint (matches ssh-keygen -lf)")
    else:
        fail("ssh pull: the overlay shows the fingerprint", "want %s on:\n%s" % (fingerprint, screen))
    if "trust and add to known_hosts" in screen and "[127.0.0.1]:" + port in screen:
        ok("ssh pull: the overlay names the host and says what y does")
    else:
        fail("ssh pull: the overlay names the host and says what y does", screen)
    if not os.path.exists(known_hosts):
        ok("ssh pull: nothing is written to known_hosts while the question is open")
    else:
        fail("ssh pull: nothing is written while the question is open", known_hosts)

    s.send("n")
    s.drain(0.5)
    now, _, _ = git(client, "rev-parse", "HEAD")
    if now == old_head and not os.path.exists(known_hosts) and "not trusted" in s.text():
        ok("ssh pull: n declines -- HEAD unmoved, known_hosts not created, the status line says so")
    else:
        fail("ssh pull: n declines", "head=%r known_hosts=%r\n%s" % (now, os.path.exists(known_hosts), s.text()))

    s.send("F")
    s.send("p")
    wait_for(s, "not known")
    s.send("y")
    got = ""
    deadline = time.time() + 20
    while time.time() < deadline:
        s.drain(0.3)
        got, _, _ = git(client, "rev-parse", "HEAD")
        if got == upstream:
            break
    if got == upstream:
        ok("ssh pull: y trusts the key and the pull fast-forwards HEAD to origin's tip")
    else:
        fail("ssh pull: y trusts and pulls", "head=%r want=%r\n%s" % (got, upstream, s.text()))
    status, _, _ = git(client, "status", "--porcelain")
    _, fsck_err, fsck_rc = git(client, "fsck", "--strict")
    if status == "" and fsck_rc == 0 and os.path.exists(os.path.join(client, "up1.txt")):
        ok("ssh pull: the working tree is updated; git status and git fsck --strict are clean")
    else:
        fail("ssh pull: tree and fsck", "status=%r fsck=%r" % (status, fsck_err))
    found = subprocess.run(
        ["ssh-keygen", "-F", "[127.0.0.1]:" + port, "-f", known_hosts], capture_output=True, text=True
    )
    if found.returncode == 0 and "ssh-ed25519" in found.stdout and fingerprint:
        ok("ssh pull: the line y appended is found by ssh-keygen -F (plain, not hashed)")
    else:
        fail("ssh pull: known_hosts line", found.stdout + found.stderr)
    if "pulled" in s.text():
        ok("ssh pull: the status line reports the pull")
    else:
        fail("ssh pull: the status line reports the pull", s.text())

    # --- push: the host is known now, so no question ---------------------------
    commit(client, "mine.txt", "from the client\n", "client commit")
    s.send("P")
    s.send("p")
    mine, _, _ = git(client, "rev-parse", "HEAD")
    remote_tip = ""
    deadline = time.time() + 20
    while time.time() < deadline:
        s.drain(0.3)
        remote_tip, _, _ = git(bare, "rev-parse", "main")
        if remote_tip == mine:
            break
    if remote_tip == mine:
        ok("ssh push: P p pushes to a known host without asking")
    else:
        fail("ssh push: P p", "remote=%r want=%r\n%s" % (remote_tip, mine, s.text()))
    _, fsck_err, fsck_rc = git(bare, "fsck", "--strict")
    if fsck_rc == 0:
        ok("ssh push: the remote repository passes git fsck --strict")
    else:
        fail("ssh push: remote fsck", fsck_err)

    # --- a non-fast-forward is refused with a message --------------------------
    commit(other, "up2.txt", "again\n", "upstream 2")
    git(other, "pull", "-q", "--no-rebase", "origin", "main", env=GIT_ENV)
    git(other, "push", "-q", "origin", "main", env=GIT_ENV)
    commit(client, "mine2.txt", "stale\n", "client commit 2")
    before, _, _ = git(bare, "rev-parse", "main")
    s.send("P")
    s.send("p")
    s.drain(1.5)
    after, _, _ = git(bare, "rev-parse", "main")
    if after == before and ("fetch first" in s.text() or "not a fast-forward" in s.text()):
        ok("ssh push: a stale branch is refused with a message; the remote is untouched")
    else:
        fail("ssh push: stale branch refused", "before=%r after=%r\n%s" % (before, after, s.text()))
    rc = s.quit()
    if rc == 0:
        ok("ssh: the client exits cleanly after the ssh operations")
    else:
        fail("ssh: the client exits cleanly", "returncode=%r" % rc)

    # --- a changed host key is refused, with no way to accept it ---------------
    with open(other_pub) as f:
        other_key = " ".join(f.read().split()[:2])
    with open(known_hosts, "w") as f:
        f.write("[127.0.0.1]:%s %s\n" % (port, other_key))
    git(client, "checkout", "-q", "main", env=GIT_ENV)
    git(client, "reset", "-q", "--hard", "HEAD~1", env=GIT_ENV)
    head_before, _, _ = git(client, "rev-parse", "HEAD")
    kh_before = open(known_hosts).read()
    s2 = Session(binpath, client)
    s2.send("F")
    s2.send("p")
    wait_for(s2, "REFUSED")
    screen = s2.text()
    if "REFUSED" in screen and "does not match" in screen:
        ok("ssh pull: a host-key mismatch is refused outright")
    else:
        fail("ssh pull: a host-key mismatch is refused", screen)
    if "trust and add" not in screen:
        ok("ssh pull: a mismatch offers no way to trust the new key")
    else:
        fail("ssh pull: a mismatch must not offer to trust", screen)
    now, _, _ = git(client, "rev-parse", "HEAD")
    if now == head_before and open(known_hosts).read() == kh_before:
        ok("ssh pull: after the mismatch HEAD and known_hosts are untouched")
    else:
        fail("ssh pull: after the mismatch", "head=%r want=%r" % (now, head_before))
    s2.quit()
    return 1 if pty_e2e.failures else 0


if __name__ == "__main__":
    sys.exit(main())
