#!/usr/bin/env python3
"""Line-level staging in the diff view, driven under a real pty, against `git apply`.

    python3 tests/pty_lines.py <ourgitui-binary> <scratch-dir>

For each case of `oracles/oracle_lines.NAMED` (add-only, delete-only, mixed, new and
deleted files, a missing newline at the end of the file, CRLF...) this builds a
fixture repository and an identical copy, opens the file's diff in `ourgitui`, selects
a range of rows with `v`/`j` and acts on it:

    space  in the unstaged / untracked view   stage the lines
    space  in the staged view                  unstage them
    x y    in the unstaged / untracked view   discard them

The copy is the oracle: the same selection as a patch (`oracle_lines.patch_for`),
applied with `git apply --cached` (`-R` for unstaging) or, for a discard, `git
apply -R` to the file. The two repositories must then agree on `git ls-files -s`,
`git diff --cached` and `git diff`, the working file must be byte-identical, and
`git fsck --strict` must be clean.
"""
import os
import shutil
import subprocess
import sys
import threading
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "oracles"))

import oracle_lines  # noqa: E402
import pty_e2e  # noqa: E402
from pty_e2e import GIT_ENV, Session, git, make_fixture  # noqa: E402

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
    with open(path, "wb") as f:
        f.write(data)


def commit_all(fx, message):
    git(fx, "add", "-A", env=GIT_ENV)
    git(fx, "commit", "-q", "-m", message, env=GIT_ENV)


def hunk_rows(ops, context=3):
    """The view's rows for `ops`: [("header", None) | ("line", op index)]."""
    changed = [i for i, (k, _) in enumerate(ops) if k != b" "]
    groups = []
    for i in changed:
        if groups and i - groups[-1][1] - 1 <= 2 * context:
            groups[-1][1] = i
        else:
            groups.append([i, i])
    rows = []
    for first, last in groups:
        rows.append(("header", None))
        for i in range(max(0, first - context), min(len(ops), last + context + 1)):
            rows.append(("line", i))
    return rows


def build(root, name, case, view):
    """A fixture for the case; returns (fixture, section) or None to skip it."""
    _, old, new = case[0], case[1], case[2]
    fx = os.path.join(root, name)
    fx = make_fixture(root, name)
    write(os.path.join(fx, "README"), b"readme\n")
    f = os.path.join(fx, "lines.txt")
    if view == "staged":
        if old:
            write(f, old)
        commit_all(fx, "base")
        if new:
            write(f, new)
            git(fx, "add", "lines.txt", env=GIT_ENV)
        else:
            git(fx, "rm", "-q", "lines.txt", env=GIT_ENV)
        return fx, "staged"
    if old:
        write(f, old)
        commit_all(fx, "base")
        if new:
            write(f, new)
        else:
            os.remove(f)
        return fx, "unstaged"
    commit_all(fx, "base")
    write(f, new)
    return fx, "untracked"


def run_case(binpath, root, case, view, action):
    name = "%s-%s-%s" % (view, action, case[0])
    old, new = case[1], case[2]
    if old == new:
        return
    scratch = os.path.join(root, "ops-" + name)
    os.makedirs(scratch)
    write(os.path.join(scratch, "old"), old)
    write(os.path.join(scratch, "new"), new)
    ops = oracle_lines.git_ops(os.path.join(scratch, "old"), os.path.join(scratch, "new"))
    picked = case[3](ops)
    if not picked:
        return
    rows = hunk_rows(ops)
    row_of = {op: r for r, (kind, op) in enumerate(rows) if kind == "line"}
    low, high = min(row_of[i] for i in picked), max(row_of[i] for i in picked)
    selected = set(i for i in range(len(ops)) if ops[i][0] != b" " and low <= row_of[i] <= high)
    built = build(root, name, case, view)
    fx, section = built
    oracle = fx + "-oracle"
    shutil.copytree(fx, oracle)
    keys = "/lines.txt\r" + "d" + "j" * low
    if high > low:
        keys += "v" + "j" * (high - low)
    session = Session(binpath, fx)
    session.send(keys)
    if action == "discard":
        session.send("x")
        shown = session.text()
        session.send("y")
    else:
        shown = session.text()
        session.send(" ")
    session.quit()

    # --- the oracle: the same selection as a patch, applied by git -------------
    staging = view != "staged"
    patch = oracle_lines.patch_for(ops, selected, staging if action != "discard" else False)
    if patch:
        patch = patch.replace(b"--- a/f\n+++ b/f\n", b"--- a/lines.txt\n+++ b/lines.txt\n", 1)
    patch_path = os.path.join(oracle, "p.patch")
    write(patch_path, patch)
    if action == "discard":
        # worktree file with the selected lines undone: git apply -R on the file
        if new:
            r = subprocess.run(["git", "apply", "-R", "--whitespace=nowarn", "--unidiff-zero", "p.patch"], cwd=oracle, capture_output=True)
        else:
            # the file is gone: restore it from the patch alone
            write(os.path.join(oracle, "lines.txt"), b"")
            r = subprocess.run(["git", "apply", "-R", "--whitespace=nowarn", "--unidiff-zero", "p.patch"], cwd=oracle, capture_output=True)
        if r.returncode != 0:
            check(name, False, "oracle: " + r.stderr.decode())
            return
        # an untracked file left empty is removed by the client
        want_removed = (not old) and not open(os.path.join(oracle, "lines.txt"), "rb").read()
        ours_exists = os.path.exists(os.path.join(fx, "lines.txt"))
        if want_removed:
            check(name + ": file removed", not ours_exists, "file still there")
        else:
            got = open(os.path.join(fx, "lines.txt"), "rb").read() if ours_exists else None
            want = open(os.path.join(oracle, "lines.txt"), "rb").read()
            check(name + ": working file equals git apply -R", got == want, "got %r want %r" % (got, want))
        ls_ours, _, _ = git(fx, "ls-files", "-s")
        ls_orc, _, _ = git(oracle, "ls-files", "-s")
        check(name + ": index untouched by a discard", ls_ours == ls_orc, "%r vs %r" % (ls_ours, ls_orc))
    else:
        if view == "untracked":
            empty = subprocess.run(["git", "hash-object", "-w", "--stdin"], cwd=oracle, input=b"", capture_output=True).stdout.decode().strip()
            git(oracle, "update-index", "--add", "--cacheinfo", "100644,%s,lines.txt" % empty)
        cmd = ["git", "apply", "--cached", "--whitespace=nowarn", "--unidiff-zero"]
        if view == "staged":
            cmd.append("-R")
        r = subprocess.run(cmd + ["p.patch"], cwd=oracle, capture_output=True)
        if r.returncode != 0:
            check(name, False, "oracle: " + r.stderr.decode())
            return
        ls_ours, _, _ = git(fx, "ls-files", "-s")
        ls_orc, _, _ = git(oracle, "ls-files", "-s")
        check(name + ": index equals git apply --cached", ls_ours == ls_orc, "ours %r git %r\n%s" % (ls_ours, ls_orc, shown))
        dc_ours, _, _ = git(fx, "diff", "--cached")
        dc_orc, _, _ = git(oracle, "diff", "--cached")
        check(name + ": git diff --cached agrees", dc_ours == dc_orc, "ours %r git %r" % (dc_ours, dc_orc))
        d_ours, _, _ = git(fx, "diff")
        d_orc, _, _ = git(oracle, "diff")
        check(name + ": git diff agrees", d_ours == d_orc, "ours %r git %r" % (d_ours, d_orc))
        f = os.path.join(fx, "lines.txt")
        same = (os.path.exists(f) == bool(new)) and (not new or open(f, "rb").read() == new)
        check(name + ": working file untouched", same)
    fsck, _, code = git(fx, "fsck", "--strict")
    check(name + ": fsck --strict clean", code == 0 and "error" not in fsck, fsck)


def main():
    binpath = os.path.abspath(sys.argv[1])
    root = os.path.abspath(sys.argv[2])
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(root)
    cases = oracle_lines.NAMED
    jobs = [(case, "unstaged", "stage") for case in cases]
    jobs += [(case, "staged", "unstage") for case in cases]
    jobs += [(case, "unstaged", "discard") for case in cases[:12] + cases[16:24]]
    with ThreadPoolExecutor(max_workers=8) as pool:
        for future in [pool.submit(run_case, binpath, root, c, v, a) for c, v, a in jobs]:
            future.result()

    # --- the keys, not the bytes ---------------------------------------------
    old = b"a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn\n"
    new = b"a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nM\nn\n"
    fx = make_fixture(root, "keys")
    write(os.path.join(fx, "lines.txt"), old)
    commit_all(fx, "base")
    write(os.path.join(fx, "lines.txt"), new)
    s = Session(binpath, fx)
    s.send("/lines.txt\rd")
    check("lines: the footer advertises v", "v lines" in s.text(), s.text())
    s.send("v")
    check("visual: v shows a selection message", "visual: 0 changed line(s) selected" in s.text(), s.text())
    check("visual: the title says [visual]", "[visual]" in s.text(), s.text())
    s.send("jj")
    check("visual: j extends the count", "visual: 1 changed line(s) selected" in s.text(), s.text())
    s.send("\x1b")
    check("visual: Escape cancels the range and keeps the diff open", "cancelled" in s.text() and "diff: " in s.text() and "[visual]" not in s.text(), s.text())
    s.send("v")
    s.send("v")
    check("visual: v again cancels", "cancelled" in s.text() and "[visual]" not in s.text(), s.text())
    s.send("kk")  # the first hunk's header
    s.send(" ")
    ls1, _, _ = git(fx, "diff", "--cached", "--numstat")
    check("lines: space on a hunk header stages the whole hunk", ls1 == "1\t1\tlines.txt", ls1)
    s.quit()
    fsck, _, code = git(fx, "fsck", "--strict")
    check("lines: fsck clean after hunk staging by header", code == 0, fsck)

    # a context line alone is refused with a message and changes nothing
    fx2 = make_fixture(root, "context")
    write(os.path.join(fx2, "lines.txt"), b"a\nb\nc\n")
    commit_all(fx2, "base")
    write(os.path.join(fx2, "lines.txt"), b"a\nB\nc\n")
    s2 = Session(binpath, fx2)
    s2.send("/lines.txt\rdj ")
    cached, _, _ = git(fx2, "diff", "--cached")
    check("lines: space on a context line is refused", "not a changed line" in s2.text() and cached == "", s2.text())
    s2.send("v")
    s2.send("x")
    check("lines: x on a one-context-line selection is refused too", "not a changed line" in s2.text(), s2.text())
    s2.send("\x1b")
    s2.send("jx")
    check("discard: x asks first", "discard 1 line(s) of lines.txt" in s2.text(), s2.text())
    s2.send("n")
    check("discard: any key but y cancels", "discard cancelled" in s2.text() and open(os.path.join(fx2, "lines.txt"), "rb").read() == b"a\nB\nc\n", s2.text())
    s2.quit()

    # a symlink and a binary file are refused
    fx3 = make_fixture(root, "binary")
    write(os.path.join(fx3, "lines.txt"), b"a\x00b\n")
    commit_all(fx3, "base")
    write(os.path.join(fx3, "lines.txt"), b"a\x00c\n")
    s3 = Session(binpath, fx3)
    s3.send("/lines.txt\rd v ")
    cached, _, _ = git(fx3, "diff", "--cached")
    check("lines: a binary file is refused", cached == "", cached)
    s3.quit()
    return failures


if __name__ == "__main__":
    sys.exit(1 if main() > 0 else 0)
