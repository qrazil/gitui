#!/usr/bin/env python3
"""mgit's command line under a real pty: the repository path operand, `--mouse
on|off` against `M31GIT_MOUSE`, the refusals and their exit status.

    python3 tests/pty_cli.py <mgit-binary> <scratch-dir>

The mouse is asked for with the DEC private modes 1000-1006 (`ESC [ ? 100x h`);
whether those escapes are in what mgit writes is what is checked.
"""
import os
import pty
import re
import select
import subprocess
import sys
import time

binpath, scratch = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
os.makedirs(scratch, exist_ok=True)
failures = 0
MOUSE = re.compile(rb"\x1b\[\?100[0-6]h")


def check(name, condition, detail=""):
    global failures
    if condition:
        print("ok   " + name, flush=True)
    else:
        failures += 1
        print("FAIL " + name + ": " + detail, flush=True)


def env_with(**extra):
    env = dict(os.environ)
    env["TERM"] = "xterm"
    for key in ("M31GIT_MOUSE", "GITUI_MOUSE"):
        env.pop(key, None)
    env.update(extra)
    return env


def run(args, cwd, env, quit_keys=True):
    """mgit on a pty; what it wrote and its exit status."""
    master, slave = pty.openpty()
    proc = subprocess.Popen([binpath] + args, stdin=slave, stdout=slave, stderr=slave, cwd=cwd, env=env)
    os.close(slave)
    out = b""

    def drain(timeout):
        nonlocal out
        while True:
            ready, _, _ = select.select([master], [], [], timeout)
            if not ready:
                return
            try:
                chunk = os.read(master, 65536)
            except OSError:
                return
            if not chunk:
                return
            out += chunk

    time.sleep(0.5)
    drain(0.4)
    if proc.poll() is None and quit_keys:
        try:
            os.write(master, b"q")
        except OSError:
            pass
        drain(0.4)
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    drain(0.1)
    os.close(master)
    return out, proc.returncode


def plain(args, env=None):
    proc = subprocess.run([binpath] + args, capture_output=True, text=True, env=env or env_with(), stdin=subprocess.DEVNULL)
    return proc.stdout, proc.stderr, proc.returncode


repo = os.path.join(scratch, "repo")
elsewhere = os.path.join(scratch, "elsewhere")
os.makedirs(repo, exist_ok=True)
os.makedirs(elsewhere, exist_ok=True)
genv = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@x", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@x")
subprocess.run(["git", "init", "-q", "-b", "main", repo], env=genv, check=True)
with open(os.path.join(repo, "a.txt"), "w") as f:
    f.write("one\n")
subprocess.run(["git", "-C", repo, "add", "-A"], env=genv, check=True)
subprocess.run(["git", "-C", repo, "commit", "-q", "-m", "one"], env=genv, check=True)

out, rc = run(["--mouse", "off", repo], elsewhere, env_with())
check("--mouse off: no mouse reports asked for", not MOUSE.search(out), repr(out[:200]))
check("--mouse off: quits with 0", rc == 0, str(rc))
out, rc = run(["--mouse", "on", repo], elsewhere, env_with())
check("--mouse on: mouse reports asked for", bool(MOUSE.search(out)), repr(out[:200]))
out, rc = run([repo], elsewhere, env_with())
check("default: mouse reports asked for", bool(MOUSE.search(out)), repr(out[:200]))
out, rc = run([repo], elsewhere, env_with(M31GIT_MOUSE="off"))
check("M31GIT_MOUSE=off: no mouse reports", not MOUSE.search(out), repr(out[:200]))
out, rc = run([repo, "--mouse", "on"], elsewhere, env_with(M31GIT_MOUSE="off"))
check("--mouse on beats M31GIT_MOUSE=off", bool(MOUSE.search(out)), repr(out[:200]))
out, rc = run(["--mouse", "off"], repo, env_with())
check("no path: the current directory, --mouse off", not MOUSE.search(out) and b"main" in out, repr(out[:300]))
out, rc = run([repo], elsewhere, env_with())
check("the path operand opens that repository", b"main" in out, repr(out[:300]))

o, e, rc = plain(["--mouse", "sideways", repo])
check("--mouse sideways: refused with 2", rc == 2 and "needs one of on, off" in e, e)
o, e, rc = plain(["--no-mouse", repo])
check("--no-mouse: refused with 2 and a suggestion", rc == 2 and "--no-mouse" in e, e)
o, e, rc = plain(["-h"])
check("-h: refused, names --help", rc == 2 and "--help" in e, e)
o, e, rc = plain(["--help"])
check("--help: usage, exit 0", rc == 0 and "usage: mgit" in o and "--mouse on|off" in o, o)
o, e, rc = plain(["--version"])
check("--version", rc == 0 and re.match(r"mgit \d+\.\d+\.\d+", o) is not None, o)
o, e, rc = plain(["--completions", "bash"])
check("--completions bash", rc == 0 and "--mouse" in o, o[:100])
o, e, rc = plain([os.path.join(scratch, "elsewhere")])
check("not a repository: exit 1", rc == 1 and "not a git repository" in e, e + str(rc))
o, e, rc = plain([repo])
check("no terminal: exit 1", rc == 1 and "not a terminal" in e, e + str(rc))

print("%d failure(s)" % failures)
sys.exit(1 if failures else 0)
