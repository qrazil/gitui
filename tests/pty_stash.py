#!/usr/bin/env python3
"""The stash UI (`z`, the Stashes section, the list overlay) driven under a real
pty, against real git as the oracle.

    python3 tests/pty_stash.py <ourgitui-binary> <scratch-dir>

Each case builds the same fixture twice. In one copy `ourgitui` is driven; in the
other, real `git stash ...` does the same job. With the identity and the dates
fixed the two repositories must then be indistinguishable: same HEAD, same
`refs/stash`, same stash log, same index and status and files. `git fsck --strict`
must be clean.
"""
import hashlib
import os
import shutil
import subprocess
import sys
import threading
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from pty_e2e import CLIENT_ENV, Session  # noqa: E402

ENV = dict(CLIENT_ENV)
for who in ("AUTHOR", "COMMITTER"):
    ENV["GIT_%s_NAME" % who] = "Stash_Tester"
    ENV["GIT_%s_EMAIL" % who] = "stash@example.com"
    ENV["GIT_%s_DATE" % who] = "1700000000 +0000"

failures = 0
lock = threading.Lock()


def check(name, condition, detail=""):
    global failures
    with lock:
        if condition:
            print("ok   " + name, flush=True)
        else:
            failures += 1
            print("FAIL " + name + ": " + detail, flush=True)


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def run(fx, *args):
    return subprocess.run(["git", "-C", fx] + list(args), capture_output=True, text=True, env=ENV)


def fixture(root, name):
    fx = os.path.join(root, name)
    os.makedirs(fx)
    run(fx, "init", "-q", "-b", "main")
    write(fx + "/a.txt", b"one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n")
    write(fx + "/b.txt", b"bee\n")
    write(fx + "/dir/c.txt", b"see\n")
    run(fx, "add", ".")
    run(fx, "commit", "-q", "-m", "base commit")
    # staged and unstaged edits, a staged add, an unstaged delete, untracked files
    write(fx + "/a.txt", b"one\nTWO\nthree\nfour\nfive\nsix\nseven\neight\nNINE\nten\n")
    run(fx, "add", "a.txt")
    write(fx + "/a.txt", b"one\nTWO\nthree\nfour\nfive\nsix\nseven\neight\nNINE\nTEN\n")
    write(fx + "/b.txt", b"bee\nsecond\n")
    os.remove(fx + "/dir/c.txt")
    write(fx + "/new.txt", b"brand new\n")
    run(fx, "add", "new.txt")
    write(fx + "/u.txt", b"untracked\n")
    write(fx + "/dir/u2.txt", b"untracked too\n")
    return fx


def state(fx):
    out = []
    out.append("HEAD " + run(fx, "rev-parse", "HEAD").stdout.strip())
    out.append("STASH " + run(fx, "rev-parse", "-q", "--verify", "refs/stash").stdout.strip())
    out.append(run(fx, "status", "--porcelain=v1", "-uall").stdout)
    out.append(run(fx, "ls-files", "-s").stdout)
    out.append(run(fx, "stash", "list").stdout)
    out.append(run(fx, "branch", "--list").stdout)
    for base, dirs, files in os.walk(fx):
        dirs[:] = sorted(d for d in dirs if d != ".git")
        for f in sorted(files):
            p = os.path.join(base, f)
            out.append("%s %o %s" % (os.path.relpath(p, fx), os.stat(p).st_mode & 0o777, hashlib.sha1(open(p, "rb").read()).hexdigest()[:12]))
    log = os.path.join(fx, ".git/logs/refs/stash")
    if os.path.exists(log):
        out.append(open(log).read())
    return "\n".join(out)


def same(name, ours, theirs):
    a, b = state(ours), state(theirs)
    if a == b:
        check(name, True)
    else:
        al, bl = a.split("\n"), b.split("\n")
        diff = [("ours: " + x) for x in al if x not in bl] + [("git:  " + x) for x in bl if x not in al]
        check(name, False, "\n".join(diff[:10]))
    fsck = run(ours, "fsck", "--strict")
    check(name + ": fsck --strict clean", fsck.returncode == 0 and "error" not in fsck.stdout + fsck.stderr, fsck.stdout + fsck.stderr)


def pair(root, name, prepare=None):
    """Two identical fixtures (-ours driven by ourgitui, -git by git); `prepare(fx)` runs on both."""
    base = fixture(root, name + "-src")
    ours, theirs = os.path.join(root, name + "-ours"), os.path.join(root, name + "-git")
    shutil.copytree(base, ours)
    shutil.copytree(base, theirs)
    shutil.rmtree(base)
    if prepare:
        prepare(ours)
        prepare(theirs)
    return ours, theirs


def stash_two(fx):
    """Two stashes made by git itself, with the working tree dirty again afterwards."""
    run(fx, "stash", "push", "-q", "-u", "-m", "first")
    write(fx + "/b.txt", b"bee\nlater\n")
    write(fx + "/extra.txt", b"extra\n")
    run(fx, "add", "extra.txt")
    run(fx, "stash", "push", "-q", "-m", "second")


def case_push(binpath, root, name, keys, git_args, typed=""):
    ours, theirs = pair(root, name)
    s = Session(binpath, ours, env=ENV)
    s.send(keys)
    if typed:
        s.send(typed + "\r")
    shown = s.text()
    s.quit()
    run(theirs, "stash", "push", "-q", *git_args)
    same("push " + name, ours, theirs)
    return shown


def main():
    binpath = os.path.abspath(sys.argv[1])
    root = os.path.abspath(sys.argv[2])
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(root)
    jobs = []

    def add(fn, *args):
        jobs.append((fn, args))

    # --- pushing ------------------------------------------------------------------
    add(case_push, "plain", "zz", [])
    add(case_push, "untracked", "zu", ["-u"])
    add(case_push, "keep-index", "zk", ["-k"])
    add(case_push, "message", "zm", ["-m", "hello world"], "hello world")

    # --- acting on stashes git made: the newest, then the one under the cursor -----
    def acting(name, keys, git_args, expect, dirty):
        def run_case(binpath, root):
            ours, theirs = pair(root, name, lambda fx: (stash_two(fx), dirty(fx)))
            s = Session(binpath, ours, env=ENV)
            s.send(keys)
            shown = s.text()
            s.quit()
            run(theirs, "stash", *git_args)
            same(name, ours, theirs)
            if expect:
                check(name + ": message line", expect in shown, shown)
        return run_case

    def nothing(fx):
        pass

    def clean_tree(fx):
        run(fx, "checkout", "-q", "--", ".")
        run(fx, "reset", "-q", "--hard")
        run(fx, "clean", "-fdq")

    add(acting("pop-newest", "zp", ["pop", "-q"], "popped stash@{0}", clean_tree))
    add(acting("apply-newest", "za", ["apply", "-q"], "applied stash@{0}", clean_tree))
    add(acting("apply-index", "zA", ["apply", "-q", "--index"], "applied stash@{0}", clean_tree))
    add(acting("pop-under-cursor", "/stash@{1}\rzp", ["pop", "-q", "stash@{1}"], "popped stash@{1}", clean_tree))
    add(acting("drop-confirmed", "zdy", ["drop", "-q"], "dropped stash@{0}", nothing))
    add(acting("drop-under-cursor", "/stash@{1}\rzdy", ["drop", "-q", "stash@{1}"], "dropped stash@{1}", nothing))
    add(acting("drop-cancelled", "zdn", ["list"], "drop cancelled", nothing))
    add(acting("branch", "zbtopic\r", ["branch", "topic"], "created topic", clean_tree))

    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = []
        for fn, args in jobs:
            if fn is case_push:
                futures.append(pool.submit(fn, binpath, root, *args))
            else:
                futures.append(pool.submit(fn, binpath, root))
        for f in futures:
            f.result()

    # --- the screens ----------------------------------------------------------------
    ours, _ = pair(root, "screens", stash_two)
    s = Session(binpath, ours, env=ENV)
    t = s.text()
    check("outline: a Stashes section with the count", "Stashes (2)" in t, t)
    s.send("/stash@{0}\r")
    t = s.text()
    check("outline: a stash row shows its reflog label", "stash@{0}: On main: second" in t, t)
    s.send("z")
    t = s.text()
    check("menu: z opens the stash menu", "stash" in t and "pop: apply the stash and drop it" in t, t)
    s.send("\x1b")
    check("menu: escape closes it", "pop: apply the stash and drop it" not in s.text(), s.text())
    s.send("zl")
    t = s.text()
    check("list: z, l opens the list with both stashes", "stashes (2)" in t and "stash@{1}: On main: first" in t, t)
    check("list: the diff preview shows the highlighted stash", "diff --git a/b.txt b/b.txt" in t and "+later" in t, t)
    s.send("j")
    t = s.text()
    check("list: j moves to the next stash and its diff", "stash@{1}" in t and "+later" not in t and "+++ b/a.txt" in t, t)
    s.send("\x1b")
    check("list: escape closes it", "stashes (2)" not in s.text(), s.text())
    s.send("/stash@{1}\r\r")
    t = s.text()
    check("outline: Enter on a stash row opens the list at it", "stashes (2)" in t and "+++ b/a.txt" in t, t)
    s.send("\x1b")
    s.send("zdn")
    check("drop: any key but y keeps the stash", "drop cancelled" in s.text(), s.text())
    s.send("@")
    t = s.text()
    check("log: nothing written by the cancelled drop", "stash drop" not in t, t)
    s.send("\x1b")
    s.send("?")
    t = s.text()
    check("help: lists the stash keys", "stash" in t, t)
    s.quit()

    # a refused apply leaves everything alone and says why
    ours, theirs = pair(root, "refused", lambda fx: run(fx, "stash", "push", "-q"))
    write(ours + "/a.txt", b"local edit\n")
    write(theirs + "/a.txt", b"local edit\n")
    s = Session(binpath, ours, env=ENV)
    s.send("za")
    t = s.text()
    s.quit()
    r = run(theirs, "stash", "apply", "-q")
    check("apply: refused over local changes, as git does", r.returncode != 0 and "refused" in t, t)
    same("apply refused leaves the repository as it was", ours, theirs)

    # a pop that has to merge and conflicts: git's conflicted state, the stash kept
    def moved_on(fx):
        run(fx, "stash", "push", "-q")
        write(fx + "/a.txt", b"one\ndeux\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n")
        run(fx, "commit", "-q", "-am", "head moved")

    ours, theirs = pair(root, "mergepop", moved_on)
    s = Session(binpath, ours, env=ENV)
    s.send("zp")
    t = s.text()
    check("pop: conflicts are reported and the stash is kept", "stopped on conflicts in a.txt" in t and "stash@{0} is kept" in t, t)
    check("pop: the outline lists the unmerged path", "a.txt" in t and "Stashes (1)" in t, t)
    s.quit()
    r = run(theirs, "stash", "pop", "-q")
    check("pop: git conflicts too", r.returncode != 0)
    same("pop that conflicts leaves git's state", ours, theirs)

    # nothing to stash
    ours, _ = pair(root, "nothing", lambda fx: (run(fx, "stash", "push", "-q", "-u")))
    s = Session(binpath, ours, env=ENV)
    s.send("zz")
    check("push: nothing to save is said, not done", "no local changes to save" in s.text(), s.text())
    s.send("@")
    check("log: the refused push is not logged", "stash push" not in s.text(), s.text())
    s.send("\x1b")
    s.send("zp")
    s.send("zp")
    s.quit()

    # the command log
    ours, _ = pair(root, "logged")
    s = Session(binpath, ours, env=ENV)
    s.send("zuzp")
    s.send("@")
    t = s.text()
    check("log: push and pop each leave a line", "stash push -u" in t and "stash pop stash@{0}" in t, t)
    s.quit()
    return failures


if __name__ == "__main__":
    sys.exit(1 if main() > 0 else 0)
