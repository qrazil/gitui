#!/usr/bin/env python3
"""Syntax highlighting under a real pty: a diff, scrolling it, the toggle and
the switches.

    python3 tests/pty_highlight.py <mgit-binary> <scratch-dir>

A fixture repository with a modified C file (and a Python file, a commit to
show) is opened in `mgit`, the file's diff is opened with `d`, and the
bytes the client writes are read back for their SGR colours: a C keyword is
magenta (palette 5) and bold, a string green (2), a comment bright black (8),
the `+`/`-` markers keep green/red. Then a 5000-line diff is scrolled, the
screen must stay right (text of the last rows) and the redraws must be quick;
`C` turns the colours off and on; `NO_COLOR`, `M31GIT_SYNTAX=off` and
`git config mgit.syntax off` each start with them off.
"""
import os
import re
import select
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pty_e2e  # noqa: E402
from pty_e2e import CLIENT_ENV, GIT_ENV, Session, git, make_fixture  # noqa: E402

failures = 0


def check(name, condition, detail=""):
    global failures
    if condition:
        print("ok   " + name, flush=True)
    else:
        failures += 1
        print("FAIL " + name + ": " + detail, flush=True)


SGR = re.compile(rb"\x1b\[([0-9;]*)m")


def colours_of(raw, word):
    """The SGR sequence in force when `word` was written, or None."""
    at = raw.find(word)
    if at < 0:
        return None
    last = None
    for found in SGR.finditer(raw, 0, at):
        last = found.group(1)
    return last


def fg_of(sgr):
    """The foreground palette index an SGR parameter list sets, or None."""
    if sgr is None:
        return None
    parts = sgr.split(b";")
    index = None
    i = 0
    while i < len(parts):
        p = parts[i]
        if p == b"38" and i + 2 < len(parts) and parts[i + 1] == b"5":
            index = int(parts[i + 2])
            i += 3
            continue
        if p == b"38" and i + 4 < len(parts) and parts[i + 1] == b"2":
            index = ("rgb", parts[i + 2], parts[i + 3], parts[i + 4])
            i += 5
            continue
        if p == b"0" or p == b"":
            index = None
        elif p.isdigit() and 30 <= int(p) <= 37:
            index = int(p) - 30
        elif p.isdigit() and 90 <= int(p) <= 97:
            index = int(p) - 90 + 8
        elif p == b"39":
            index = None
        i += 1
    return index


def write(path, text):
    with open(path, "w") as f:
        f.write(text)


def commit_all(fx, message):
    git(fx, "add", "-A", env=GIT_ENV)
    git(fx, "commit", "-q", "-m", message, env=GIT_ENV)


BASE = "int main(void) {\n    return 0;\n}\n"
NEW = '// entry\nint main(void) {\n    puts("hi");\n    return 4242;\n}\n'


def fixture(root, name):
    fx = make_fixture(root, name)
    write(os.path.join(fx, "a.c"), BASE)
    write(os.path.join(fx, "notes.txt"), "plain\n")
    commit_all(fx, "base")
    write(os.path.join(fx, "a.c"), NEW)
    write(os.path.join(fx, "notes.txt"), "plain\nreturn if while\n")
    return fx


def open_diff(session, section_rows=2):
    """Unstaged section is row 1 (no untracked files); its first child row 2."""
    session.send("j")
    session.send("j")
    return session.send("d")


def main():
    if len(sys.argv) != 3:
        print("usage: pty_highlight.py <mgit-binary> <scratch-dir>", file=sys.stderr)
        return 2
    binpath = os.path.abspath(sys.argv[1])
    root = os.path.abspath(sys.argv[2])
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(root)

    env = dict(CLIENT_ENV)
    for key in ("NO_COLOR", "M31GIT_SYNTAX", "COLORFGBG"):
        env.pop(key, None)
    env["COLORFGBG"] = "15;0"

    # --- a highlighted diff -------------------------------------------------
    fx = fixture(root, "on")
    s = Session(binpath, fx, env=env)
    raw = open_diff(s)
    check("diff opens on a.c", "a.c" in s.text() and "puts" in s.text(), s.text())
    kw = fg_of(colours_of(raw, b"return"))
    check("a keyword is magenta (5)", kw == 5, repr(colours_of(raw, b"return")))
    check("a comment is bright black (8)", fg_of(colours_of(raw, b"entry")) == 8, repr(colours_of(raw, b"entry")))
    check("a string is green (2)", fg_of(colours_of(raw, b'"hi"')) == 2, repr(colours_of(raw, b'"hi"')))
    check("a type is cyan (6)", fg_of(colours_of(raw, b"int")) == 6, repr(colours_of(raw, b"int")))
    check("a number is yellow (3 on a dark terminal)", fg_of(colours_of(raw, b"4242")) == 3, repr(colours_of(raw, b"4242")))
    # the removed line "-    return 0;" keeps its red marker
    check("the diff colours the removed marker red (1)", fg_of(colours_of(raw, b"-    ")) == 1, repr(colours_of(raw, b"-    ")))
    check("the added marker is green (2)", fg_of(colours_of(raw, b"+    ")) == 2, repr(colours_of(raw, b"+    ")))

    # blame (B) the file as of HEAD: the code column is coloured too
    raw = s.send("B")
    check("blame opens", "blame a.c" in s.text(), s.text())
    check("blame: a keyword is magenta (5)", fg_of(colours_of(raw, b"return")) == 5, repr(colours_of(raw, b"return")))
    s.send("q")
    # history (H) of the file, Enter on the commit: its diff in colours
    s.send("H")
    check("history opens", "history of a.c" in s.text(), s.text())
    raw = s.send("\r")
    check("the commit view opens", "commit " in s.text() and "--- a.c" in s.text(), s.text())
    check("commit view: a keyword is magenta (5)", fg_of(colours_of(raw, b"return")) == 5, repr(colours_of(raw, b"return")))
    check("commit view: the added marker is green (2)", fg_of(colours_of(raw, b"+ ")) == 2, repr(colours_of(raw, b"+ ")))
    s.quit()

    # explicit toggling, counted: start on; one C -> off; the next -> on
    fx = fixture(root, "toggle")
    s = Session(binpath, fx, env=env)
    open_diff(s)
    raw = s.send("C")
    check("C turns syntax colours off (status says so)", "syntax colours off" in s.text(), s.text())
    check("with them off the keyword is not magenta", fg_of(colours_of(raw, b"return")) != 5, repr(colours_of(raw, b"return")))
    raw = s.send("C")
    check("C turns them on again", "syntax colours on" in s.text(), s.text())
    check("with them on the keyword is magenta again", fg_of(colours_of(raw, b"return")) == 5, repr(colours_of(raw, b"return")))
    s.quit()

    # --- the switches that start with it off --------------------------------
    for label, make_env, setup in [
        ("NO_COLOR", lambda e: dict(e, NO_COLOR="1"), None),
        ("M31GIT_SYNTAX=off", lambda e: dict(e, M31GIT_SYNTAX="off"), None),
        ("git config mgit.syntax", lambda e: dict(e), lambda fx: git(fx, "config", "mgit.syntax", "false")),
    ]:
        fx = fixture(root, "off-" + re.sub(r"\W", "", label))
        if setup:
            setup(fx)
        s = Session(binpath, fx, env=make_env(env))
        raw = open_diff(s)
        check(label + ": the diff still opens", "puts" in s.text(), s.text())
        check(label + ": keywords are not coloured", fg_of(colours_of(raw, b"return")) != 5, repr(colours_of(raw, b"return")))
        s.quit()

    # --- a large diff scrolls, correctly and quickly -------------------------
    fx = make_fixture(root, "big")
    write(os.path.join(fx, "big.c"), "int seed;\n")
    commit_all(fx, "base")
    body = "".join("int v%d = %d; /* c%d */ // t\n" % (i, i, i) for i in range(5000))
    write(os.path.join(fx, "big.c"), "int seed;\n" + body)
    s = Session(binpath, fx, env=env)
    t0 = time.time()
    open_diff(s)
    opened = time.time() - t0
    check("5000-line diff opens", "big.c" in s.text(), s.text())
    worst = 0.0
    seen = b""
    for _ in range(30):
        t = time.time()
        os.write(s.master, b"j" * 20)
        # the time to the first byte of the redraw
        select.select([s.master], [], [], 5)
        worst = max(worst, time.time() - t)
        seen = s.drain(0.1)
    check("scrolling 600 rows keeps the diff on screen", "int v" in s.text(), s.text())
    used = set()
    for found in SGR.finditer(seen):
        c = fg_of(found.group(1))
        if c is not None:
            used.add(c)
    check("scrolled rows are still coloured (number, comment)", {3, 8} <= used, repr(sorted(map(str, used))))
    check("a 20-row scroll of a 5000-line diff redraws within 0.25s (worst %.3fs, open %.2fs)" % (worst, opened), worst < 0.25)
    for _ in range(8):
        s.send("j" * 600)
    check("rows far down are right", re.search(r"v49\d\d = ", s.text()) is not None, s.text())
    s.quit()

    return failures


if __name__ == "__main__":
    sys.exit(main())
