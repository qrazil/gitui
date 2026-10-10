#!/usr/bin/env python3
"""Drive the compiled `ourgitui` binary under a real pty, against disposable
git fixtures this script builds and destroys itself -- the same discipline
`tests/test.sh`/`test_write.sh` already use for the write-path work, and
`docs/design.md`'s own "Safety" section names for this client
specifically: never a real repository, real `git` as the oracle throughout.

Run from anywhere:

    python3 tests/pty_e2e.py <ourgitui-binary> <scratch-dir>

`<scratch-dir>` is created fresh (and removed first if it already exists) --
`test_gitui.sh` passes it a directory under its own `mktemp -d`, never
anything resembling a real repository.

Every `ok`/`FAIL` line this prints is one check; the exit code is the number
of failures, so `test_gitui.sh` can both grep for `FAIL` and trust `$?`. This
is the "drive it under a pty against a disposable fixture, oracle-checked"
half of the client's test obligations (`docs/design.md`, "how you'll know
you're done and correct"); `t_gitclient.m31` and `t_gitclient_ops.m31` cover
the unit- and oracle-level checks a pty adds nothing to.
"""
import os
import pty
import select
import shutil
import subprocess
import sys
import time

failures = 0


def ok(name):
    global failures
    print("ok   " + name)


def fail(name, detail):
    global failures
    failures += 1
    print("FAIL " + name + ": " + detail)


def git(cwd, *args, env=None):
    r = subprocess.run(["git", "-C", cwd] + list(args), capture_output=True, text=True, env=env)
    # `.rstrip("\n")` only -- `git status --short`'s leading column can be a
    # space (an unstaged-only row starts " M path"), and a blanket `.strip()`
    # would eat that space off the first line and make a clean status look
    # identical to a staged one.
    return r.stdout.rstrip("\n"), r.stderr.rstrip("\n"), r.returncode


GIT_ENV = dict(os.environ)
GIT_ENV["GIT_AUTHOR_NAME"] = "Fixture"
GIT_ENV["GIT_AUTHOR_EMAIL"] = "fixture@example.com"
GIT_ENV["GIT_COMMITTER_NAME"] = "Fixture"
GIT_ENV["GIT_COMMITTER_EMAIL"] = "fixture@example.com"
GIT_ENV["GIT_AUTHOR_DATE"] = "1700000000 +0000"
GIT_ENV["GIT_COMMITTER_DATE"] = "1700000000 +0000"

CLIENT_ENV = dict(os.environ)
CLIENT_ENV["TERM"] = "xterm"
CLIENT_ENV["GIT_AUTHOR_NAME"] = "Client"
CLIENT_ENV["GIT_AUTHOR_EMAIL"] = "client@example.com"
CLIENT_ENV["GIT_COMMITTER_NAME"] = "Client"
CLIENT_ENV["GIT_COMMITTER_EMAIL"] = "client@example.com"



class Screen:
    """A just-enough terminal emulator: the cursor-addressing subset the
    client's renderer emits (cursor position, cursor forward/back, erase,
    plain text), so a check can ask what is ON the screen rather than
    grep a stream of cell updates -- the renderer writes only the cells
    that changed, which splits a message across escape sequences."""

    def __init__(self, rows=24, cols=80):
        self.rows = rows
        self.cols = cols
        self.reset()

    def reset(self):
        self.cells = [[" "] * self.cols for _ in range(self.rows)]
        self.row = 0
        self.col = 0
        self.pending = b""

    def feed(self, data):
        text = (self.pending + data).decode("utf-8", errors="replace")
        self.pending = b""
        i = 0
        n = len(text)
        while i < n:
            ch = text[i]
            if ch == "\x1b":
                if i + 1 >= n:
                    self.pending = text[i:].encode()
                    return
                if text[i + 1] != "[":
                    i += 2
                    continue
                j = i + 2
                while j < n and (text[j] in "0123456789;?<>=" or text[j] in " !\"#$%&'()*+,-./"):
                    j += 1
                if j >= n:
                    self.pending = text[i:].encode()
                    return
                self.csi(text[i + 2 : j], text[j])
                i = j + 1
                continue
            if ch == "\r":
                self.col = 0
            elif ch == "\n":
                self.row = min(self.row + 1, self.rows - 1)
            elif ch >= " ":
                if 0 <= self.row < self.rows and 0 <= self.col < self.cols:
                    self.cells[self.row][self.col] = ch
                self.col += 1
            i += 1

    def csi(self, params, final):
        if params.startswith("?"):
            return
        nums = [int(x) if x.isdigit() else 0 for x in params.split(";")] if params else []
        first = nums[0] if nums and nums[0] > 0 else 1
        if final in "Hf":
            self.row = (nums[0] if len(nums) > 0 and nums[0] > 0 else 1) - 1
            self.col = (nums[1] if len(nums) > 1 and nums[1] > 0 else 1) - 1
        elif final == "C":
            self.col += first
        elif final == "D":
            self.col = max(0, self.col - first)
        elif final == "A":
            self.row = max(0, self.row - first)
        elif final == "B":
            self.row = min(self.rows - 1, self.row + first)
        elif final == "G":
            self.col = first - 1
        elif final == "K":
            mode = nums[0] if nums else 0
            if 0 <= self.row < self.rows:
                lo, hi = (self.col, self.cols) if mode == 0 else ((0, self.col + 1) if mode == 1 else (0, self.cols))
                for c in range(max(lo, 0), min(hi, self.cols)):
                    self.cells[self.row][c] = " "
        elif final == "J":
            mode = nums[0] if nums else 0
            if mode == 2 or mode == 3:
                self.cells = [[" "] * self.cols for _ in range(self.rows)]
            elif mode == 0:
                for r in range(self.row, self.rows):
                    for c in range(self.cols):
                        if r > self.row or c >= self.col:
                            self.cells[r][c] = " "

    def text(self):
        return "\n".join("".join(row).rstrip() for row in self.cells)


class Session:
    """One `ourgitui` process on a pty, in one fixture directory."""

    def __init__(self, binpath, fixture, env=None):
        self.screen = Screen()
        self.master, slave = pty.openpty()
        self.proc = subprocess.Popen(
            [binpath, fixture],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            cwd=fixture,
            env=env if env is not None else CLIENT_ENV,
        )
        os.close(slave)
        time.sleep(0.3)
        self.drain()

    def drain(self, timeout=0.35):
        out = b""
        while True:
            r, _, _ = select.select([self.master], [], [], timeout)
            if not r:
                break
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
            self.screen.feed(chunk)
        return out

    def text(self):
        """What is on the screen now."""
        return self.screen.text()

    def send(self, keys):
        try:
            os.write(self.master, keys.encode())
        except OSError:
            pass  # the child has gone (macOS reports EIO, Linux does not)
        time.sleep(0.2)
        return self.drain()

    def quit(self):
        self.send("q")
        try:
            self.proc.wait(timeout=2)
        except Exception:
            self.proc.kill()
        try:
            os.close(self.master)
        except OSError:
            pass
        return self.proc.returncode


def quiet_repo(fx):
    """No background `git maintenance` / `gc --auto` in a fixture: it is detached,
    takes `objects/maintenance.lock` and would race the copy `copy_repo` makes."""
    subprocess.run(["git", "config", "gc.auto", "0"], cwd=fx, check=True)
    subprocess.run(["git", "config", "maintenance.auto", "false"], cwd=fx, check=True)


def copy_repo(src, dst):
    """A byte-for-byte copy of a fixture repository, lock files left behind."""
    shutil.copytree(src, dst, ignore=shutil.ignore_patterns("*.lock"))


def make_fixture(root, name):
    fx = os.path.join(root, name)
    os.makedirs(fx)
    subprocess.run(["git", "init", "-q", "-b", "main", "."], cwd=fx, check=True)
    quiet_repo(fx)
    return fx


def write_editor_script(path, message):
    """A stand-in `$EDITOR`: overwrite the message file it is given with a
    fixed line and exit 0. `e` now actually runs `$EDITOR` via `os.run` and
    waits for it, so the pty tests below drive a real (if trivial) child
    process rather than editing `COMMIT_EDITMSG` out of band from Python --
    the same thing `tests/test_gitui.sh`'s own stand-in editors do for the
    non-pty, oracle-level checks of every `os.run` outcome."""
    with open(path, "w") as f:
        f.write("#!/bin/sh\n")
        f.write("cat >\"$1\" <<'STANDIN_EOF'\n")
        f.write(message + "\n")
        f.write("STANDIN_EOF\n")
        f.write("exit 0\n")
    os.chmod(path, 0o755)


def env_with_editor(editor_path):
    env = dict(CLIENT_ENV)
    env["EDITOR"] = editor_path
    return env


class Context:
    """What `pty_blame_undo.run` borrows from this file."""

    def __init__(self, binpath, root, session, make_fixture, git, git_env, ok, fail):
        self.binpath = binpath
        self.root = root
        self.Session = session
        self.make_fixture = make_fixture
        self.git = git
        self.GIT_ENV = git_env
        self.ok = ok
        self.fail = fail


def main():
    if len(sys.argv) != 3:
        print("usage: pty_e2e.py <ourgitui-binary> <scratch-dir>", file=sys.stderr)
        return 2
    binpath = os.path.abspath(sys.argv[1])
    root = os.path.abspath(sys.argv[2])
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(root)

    # --- staging an untracked file and an unstaged (modified) file ----------
    fx = make_fixture(root, "stage")
    with open(os.path.join(fx, "a.txt"), "w") as f:
        f.write("one\n")
    with open(os.path.join(fx, "b.txt"), "w") as f:
        f.write("two\n")
    git(fx, "add", "-A", env=GIT_ENV)
    git(fx, "commit", "-q", "-m", "first", env=GIT_ENV)
    with open(os.path.join(fx, "a.txt"), "a") as f:
        f.write("changed\n")
    with open(os.path.join(fx, "c.txt"), "w") as f:
        f.write("new\n")

    s = Session(binpath, fx)
    # rows: 0 untracked section, 1 c.txt, 2 unstaged section, 3 M a.txt
    s.send("j")  # -> c.txt
    s.send("s")  # stage the untracked file
    s.quit()

    got, _, _ = git(fx, "status", "--short")
    if got == " M a.txt\nA  c.txt":
        ok("stage: untracked file staged, unstaged modification untouched")
    else:
        fail("stage: untracked file staged, unstaged modification untouched", "git status --short = %r" % got)

    # now stage the remaining unstaged file (a.txt) in a fresh session, where
    # its row position is unambiguous: untracked(0), unstaged(1): M a.txt,
    # staged(1): A c.txt, commits(1).
    s2 = Session(binpath, fx)
    s2.send("j")  # row1: unstaged section -> its child "M a.txt" is row... section is row1, child row2
    s2.send("j")  # row2: M a.txt
    s2.send("s")  # stage it
    s2.quit()
    got, _, _ = git(fx, "status", "--short")
    if got == "M  a.txt\nA  c.txt":
        ok("stage: second (previously unstaged) file also staged")
    else:
        fail("stage: second (previously unstaged) file also staged", "git status --short = %r" % got)

    fsck_out, _, _ = git(fx, "fsck", "--full")
    if fsck_out == "":
        ok("stage: fsck reports nothing after two whole-file stages")
    else:
        fail("stage: fsck reports nothing after two whole-file stages", fsck_out)

    # --- unstaging: a path tracked in HEAD, and a newly-added path ----------
    fx2 = make_fixture(root, "unstage")
    with open(os.path.join(fx2, "a.txt"), "w") as f:
        f.write("one\n")
    git(fx2, "add", "-A", env=GIT_ENV)
    git(fx2, "commit", "-q", "-m", "first", env=GIT_ENV)
    with open(os.path.join(fx2, "a.txt"), "a") as f:
        f.write("changed\n")
    with open(os.path.join(fx2, "new.txt"), "w") as f:
        f.write("brand new\n")
    git(fx2, "add", "-A", env=GIT_ENV)
    # rows: untracked(0), unstaged(0), staged(2): M a.txt, A new.txt, commits(1)
    s3 = Session(binpath, fx2)
    s3.send("j")
    s3.send("j")
    s3.send("j")  # row3: M a.txt (staged section is row2, first child row3)
    s3.send("u")  # unstage a.txt -- tracked in HEAD
    s3.quit()
    got, _, _ = git(fx2, "status", "--short")
    if got == " M a.txt\nA  new.txt":
        ok("unstage: a path tracked in HEAD goes back to HEAD's version, not deleted")
    else:
        fail("unstage: a path tracked in HEAD goes back to HEAD's version, not deleted", "git status --short = %r" % got)

    # cursor reset to row0 after the reload (its old id no longer exists);
    # new.txt is now the sole staged row: untracked(0), unstaged(1): a.txt,
    # staged(1): new.txt -- row0 untracked, row1 unstaged section, row2
    # a.txt, row3 staged section, row4 new.txt.
    s4 = Session(binpath, fx2)
    s4.send("j")
    s4.send("j")
    s4.send("j")
    s4.send("j")  # row4: A new.txt
    s4.send("u")  # unstage new.txt -- never in HEAD, so dropped entirely
    s4.quit()
    got, _, _ = git(fx2, "status", "--short")
    if got == " M a.txt\n?? new.txt":
        ok("unstage: a path never in HEAD is dropped from the index, not committed empty")
    else:
        fail("unstage: a path never in HEAD is dropped from the index, not committed empty", "git status --short = %r" % got)

    fsck_out, _, _ = git(fx2, "fsck", "--full")
    dangling_only = all(line.startswith("dangling blob") for line in fsck_out.splitlines() if line)
    if dangling_only:
        ok("unstage: fsck reports nothing but expected dangling blobs")
    else:
        fail("unstage: fsck reports nothing but expected dangling blobs", fsck_out)

    # --- committing: a real $EDITOR launch (a stand-in script), finish -------
    #
    # `e` now actually runs `os.run([$EDITOR, COMMIT_EDITMSG])` and waits for
    # it -- see `GIT_client.m31`'s own header, "launching `$EDITOR`, and the
    # terminal handoff that takes" -- so this drives that for real, with a
    # stand-in editor standing in for `$EDITOR` exactly as
    # `tests/test_gitui.sh`'s own non-pty checks do for every `os.run`
    # outcome. What only a pty can prove is the terminal handoff itself: raw
    # mode and the alternate screen are left before the editor (a real child
    # process) runs, at all -- this session would simply hang or scribble
    # garbage over its own raw-mode screen otherwise -- and both are resumed
    # cleanly, with a full redraw, once it exits.
    editor_first = os.path.join(root, "editor-first.sh")
    write_editor_script(editor_first, "first commit via the interactive client")
    fx3 = make_fixture(root, "commit")
    with open(os.path.join(fx3, "a.txt"), "w") as f:
        f.write("one\n")
    git(fx3, "add", "-A", env=GIT_ENV)
    # no commit yet -- unborn branch, exactly the case `finish_commit` must
    # also handle (no parent).
    s5 = Session(binpath, fx3, env=env_with_editor(editor_first))
    s5.send("c")  # open the commit which-key overlay
    s5.send("e")  # launch the stand-in editor; exit 0 finishes the commit
    time.sleep(0.2)
    s5.drain()
    s5.quit()

    log_out, _, log_rc = git(fx3, "log", "--oneline")
    if log_rc == 0 and log_out.endswith("first commit via the interactive client"):
        ok("commit: the client's first commit (unborn branch, no parent) appears in git log")
    else:
        fail("commit: the client's first commit (unborn branch, no parent) appears in git log", "log=%r rc=%d" % (log_out, log_rc))

    status_out, _, _ = git(fx3, "status", "--short")
    if status_out == "":
        ok("commit: working tree clean after the commit (the staged file was committed)")
    else:
        fail("commit: working tree clean after the commit (the staged file was committed)", status_out)

    author_out, _, _ = git(fx3, "log", "-1", "--format=%an <%ae>")
    if author_out == "Client <client@example.com>":
        ok("commit: author identity came from GIT_AUTHOR_NAME/EMAIL")
    else:
        fail("commit: author identity came from GIT_AUTHOR_NAME/EMAIL", author_out)

    fsck_out, _, _ = git(fx3, "fsck", "--full")
    if fsck_out == "":
        ok("commit: fsck reports nothing after the client's own commit")
    else:
        fail("commit: fsck reports nothing after the client's own commit", fsck_out)

    if not os.path.exists(os.path.join(fx3, ".git", "COMMIT_EDITMSG")):
        ok("commit: COMMIT_EDITMSG removed after the editor exits 0 and the commit finishes")
    else:
        fail("commit: COMMIT_EDITMSG removed after the editor exits 0 and the commit finishes", "still present")

    # a second commit, so the tree-builder is exercised with a real parent
    # and an existing history to extend.
    editor_second = os.path.join(root, "editor-second.sh")
    write_editor_script(editor_second, "second commit")
    with open(os.path.join(fx3, "b.txt"), "w") as f:
        f.write("two\n")
    s6 = Session(binpath, fx3, env=env_with_editor(editor_second))
    s6.send("j")  # onto the untracked b.txt
    s6.send("s")  # stage it
    s6.send("c")
    s6.send("e")
    time.sleep(0.2)
    s6.drain()
    s6.quit()
    log_out, _, _ = git(fx3, "log", "--oneline")
    lines = log_out.splitlines()
    if len(lines) == 2 and lines[0].endswith("second commit") and lines[1].endswith("first commit via the interactive client"):
        ok("commit: a second commit has the first as its parent")
    else:
        fail("commit: a second commit has the first as its parent", log_out)

    parents, _, _ = git(fx3, "log", "-1", "--format=%P")
    if len(parents.split()) == 1:
        ok("commit: the second commit has exactly one parent")
    else:
        fail("commit: the second commit has exactly one parent", repr(parents))

    # --- the empty-message refusal, reached through the editor too ----------
    #
    # A stand-in editor that leaves the template untouched (comment lines
    # only) and exits 0 -- the same refusal `finish_commit`/`f` always gave,
    # now reached without a separate `f` press since a successful edit
    # finishes the commit on its own (real git's own behaviour).
    editor_noop = os.path.join(root, "editor-noop.sh")
    with open(editor_noop, "w") as f:
        f.write("#!/bin/sh\nexit 0\n")
    os.chmod(editor_noop, 0o755)
    fx4 = make_fixture(root, "empty-message")
    with open(os.path.join(fx4, "a.txt"), "w") as f:
        f.write("one\n")
    git(fx4, "add", "-A", env=GIT_ENV)
    s7 = Session(binpath, fx4, env=env_with_editor(editor_noop))
    s7.send("c")
    out = s7.send("e")  # a fresh template, untouched by the editor -- refused
    time.sleep(0.2)
    out += s7.drain()
    s7.quit()
    log_out, _, log_rc = git(fx4, "log", "--oneline")
    status_out, _, _ = git(fx4, "status", "--short")
    if log_rc != 0 and status_out == "A  a.txt" and b"aborting commit due to empty commit message" in out:
        ok("commit: an all-comment message is refused, exactly like real git")
    else:
        fail(
            "commit: an all-comment message is refused, exactly like real git",
            "log_rc=%d status=%r saw_refusal=%s" % (log_rc, status_out, b"aborting commit due to empty commit message" in out),
        )

    # --- diff: hunk-level view for a staged row and an unstaged row ----------
    #
    # One file, staged with one change and then changed again on disk -- the
    # exact "stage a file, modify it further" scenario `docs/design.md`
    # names, so both comparisons are exercised against real `git diff --cached`
    # and `git diff` (plain) in the same session. `Theme.plain` means no SGR
    # colour codes are ever written, so a rendered hunk's `+`/`-` lines and the
    # bordered title survive as plain substrings of the raw pty bytes, the same
    # way the empty-message refusal's status line does above.
    fx5 = make_fixture(root, "diff")
    with open(os.path.join(fx5, "f.txt"), "w") as f:
        f.write("a\nb\nc\n")
    git(fx5, "add", "-A", env=GIT_ENV)
    git(fx5, "commit", "-q", "-m", "first", env=GIT_ENV)
    with open(os.path.join(fx5, "f.txt"), "w") as f:  # staged change
        f.write("a\nB\nc\n")
    git(fx5, "add", "f.txt", env=GIT_ENV)
    with open(os.path.join(fx5, "f.txt"), "w") as f:  # further, unstaged change
        f.write("a\nB\nC\n")

    cached_diff, _, _ = git(fx5, "diff", "--cached", "--no-color", "--", "f.txt")
    plain_diff, _, _ = git(fx5, "diff", "--no-color", "--", "f.txt")

    # rows: untracked section(0, no children), unstaged section(1): M f.txt,
    # staged section(1): M f.txt, commits section(1) -> row0 untracked
    # section, row1 unstaged section, row2 M f.txt (unstaged), row3 staged
    # section, row4 M f.txt (staged).
    s8 = Session(binpath, fx5)
    s8.send("j")  # row1: unstaged section
    s8.send("j")  # row2: M f.txt (unstaged)
    out = s8.send("d")  # open its diff: index blob vs the working tree
    if b"diff: M  f.txt" in out and b"-c" in out and b"+C" in out:
        ok("diff: an unstaged row shows the index-vs-working-tree hunk (git diff)")
    else:
        fail("diff: an unstaged row shows the index-vs-working-tree hunk (git diff)", repr(out))

    out = s8.send("\x7f")  # Backspace: back out to the outline
    if b"Unstaged changes" in out and b"diff: M  f.txt" not in out:
        ok("diff: Backspace returns to the outline")
    else:
        fail("diff: Backspace returns to the outline", repr(out))

    s8.send("j")  # row3: staged section
    s8.send("j")  # row4: M f.txt (staged)
    out = s8.send("d")  # open its diff: HEAD's tree vs the index
    if b"diff: M  f.txt" in out and b"-b" in out and b"+B" in out:
        ok("diff: a staged row shows the HEAD-vs-index hunk (git diff --cached)")
    else:
        fail("diff: a staged row shows the HEAD-vs-index hunk (git diff --cached)", repr(out))
    s8.quit()

    if "-c" in plain_diff and "+C" in plain_diff and "-b" in cached_diff and "+B" in cached_diff:
        ok("diff: the fixture's own git diff/git diff --cached confirm the expected lines")
    else:
        fail(
            "diff: the fixture's own git diff/git diff --cached confirm the expected lines",
            "cached=%r plain=%r" % (cached_diff, plain_diff),
        )

    # --- commit log: a commit's own "Files changed" list and per-file diff --
    #
    # Two commits -- the second changes one file and adds another -- so
    # `commit_changes`'s added/modified split and its exact insertion/
    # deletion counts (not just that *something* changed) have two real,
    # different cases to get right in one fixture. `git diff --numstat` is
    # the oracle for the counts, `git diff -- <path>` for the hunk a file
    # row's own `Enter` pops -- the one row `Enter` opens a diff on directly
    # rather than folding, since a commit's own file row has nothing to fold
    # (GIT_client.m31's `State.handle_enter`).
    fx9 = make_fixture(root, "commitlog")
    with open(os.path.join(fx9, "a.txt"), "w") as f:
        f.write("line1\nline2\nline3\n")
    with open(os.path.join(fx9, "b.txt"), "w") as f:
        f.write("hello\n")
    git(fx9, "add", "-A", env=GIT_ENV)
    git(fx9, "commit", "-q", "-m", "first", env=GIT_ENV)
    with open(os.path.join(fx9, "a.txt"), "w") as f:
        f.write("line1\nCHANGED\nline3\nline4\n")
    with open(os.path.join(fx9, "c.txt"), "w") as f:
        f.write("world\n")
    git(fx9, "add", "-A", env=GIT_ENV)
    git(fx9, "commit", "-q", "-m", "second", env=GIT_ENV)

    want_numstat, _, _ = git(fx9, "diff", "--numstat", "HEAD~1", "HEAD")
    want_a_diff, _, _ = git(fx9, "diff", "--no-color", "HEAD~1", "HEAD", "--", "a.txt")

    # rows: untracked section(0), unstaged section(0), staged section(0),
    # commits section(1) -- row0 untracked, row1 unstaged, row2 staged,
    # row3 commits section (already expanded), row4 "second" (collapsed).
    s9 = Session(binpath, fx9)
    s9.send("jjj")  # row3: commits section
    s9.send("j")  # row4: "second", the most recent commit
    # Unfolding a commit is also what first computes its file list (lazily,
    # cached per commit -- GIT_client.m31's `did_compute_commit_changes`), and its
    # "Files changed" subsection opens with it by default, so one Enter shows
    # author, date, message, the subsection heading and the file rows.
    out = s9.send("\r")
    if b"Files changed (2)" in out:
        ok("commit log: expanding a commit shows its own Files changed count")
    else:
        fail("commit log: expanding a commit shows its own Files changed count", repr(out))
    if b"M  a.txt  +2 -1" in out and b"A  c.txt  +1 -0" in out:
        ok("commit log: file rows' +insertions -deletions match git diff --numstat")
    else:
        fail("commit log: file rows' +insertions -deletions match git diff --numstat", repr(out))

    s9.send("jjjj")  # author, date, message ("second"), Files changed section
    s9.send("j")  # the "M  a.txt  +2 -1" row
    out = s9.send("\r")  # Enter pops the diff directly -- no `d` needed here
    if b"diff: M  a.txt" in out and b"-line2" in out and b"+CHANGED" in out and b"+line4" in out:
        ok("commit log: Enter on a file row pops its diff, matching git diff HEAD~1 HEAD")
    else:
        fail("commit log: Enter on a file row pops its diff, matching git diff HEAD~1 HEAD", repr(out))

    out = s9.send("\x7f")  # Backspace returns to the outline, same as any other diff
    if b"Files changed" in out and b"diff: M  a.txt" not in out:
        ok("commit log: Backspace from a commit-file diff returns to the outline")
    else:
        fail("commit log: Backspace from a commit-file diff returns to the outline", repr(out))
    s9.quit()

    if "2\t1\ta.txt" in want_numstat and "1\t0\tc.txt" in want_numstat and "-line2" in want_a_diff and "+CHANGED" in want_a_diff:
        ok("commit log: the fixture's own git diff --numstat/git diff confirm the expected counts and lines")
    else:
        fail(
            "commit log: the fixture's own git diff --numstat/git diff confirm the expected counts and lines",
            "numstat=%r a_diff=%r" % (want_numstat, want_a_diff),
        )

    # --- the terminal handoff itself, under a genuinely interactive editor --
    #
    # Everything above proves `os.run`'s outcomes are handled correctly with
    # a stand-in editor that never touches the terminal. `ed` -- a real,
    # interactive, but line-oriented (so scriptable over a pty with plain
    # keystrokes) editor -- is what proves the handoff itself: that raw mode
    # and the alternate screen are genuinely suspended (ed reads and echoes
    # ordinary cooked-mode input; it would not work at all, or would garble
    # the screen, sitting on top of this program's own raw mode) and cleanly
    # resumed afterward (this session keeps talking to `ourgitui` right up to
    # a normal quit once `ed` exits).
    ed_path = shutil.which("ed")
    if ed_path is None:
        print("gitui pty: interactive $EDITOR (ed) check skipped, no ed on $PATH", file=sys.stderr)
    else:
        fx6 = make_fixture(root, "interactive-editor")
        with open(os.path.join(fx6, "a.txt"), "w") as f:
            f.write("one\n")
        git(fx6, "add", "-A", env=GIT_ENV)
        s9 = Session(binpath, fx6, env=env_with_editor(ed_path))
        s9.send("c")
        s9.send("e")  # ed starts; the template (comment lines) is its buffer
        time.sleep(0.2)
        s9.drain()
        s9.send(",d\n")  # delete every line ed was given
        s9.send("a\n")  # start appending
        s9.send("an ed-authored commit message\n")
        s9.send(".\n")  # end the append
        s9.send("w\n")  # write the file
        after_ed = s9.send("q\n")  # quit ed -- ourgitui resumes right here
        time.sleep(0.2)
        after_ed += s9.drain()
        if b"\x1b[?1049h" in after_ed:
            ok("commit: ourgitui re-enters the alternate screen after a real interactive $EDITOR exits")
        else:
            fail("commit: ourgitui re-enters the alternate screen after a real interactive $EDITOR exits", repr(after_ed[:200]))
        rc = s9.quit()  # a plain "q" still reaches ourgitui and ends it cleanly
        if rc == 0:
            ok("commit: ourgitui still responds to input and exits cleanly after the $EDITOR handoff")
        else:
            fail("commit: ourgitui still responds to input and exits cleanly after the $EDITOR handoff", "returncode=%r" % rc)

        log_out, _, log_rc = git(fx6, "log", "--oneline")
        if log_rc == 0 and log_out.endswith("an ed-authored commit message"):
            ok("commit: a message written by a real interactive editor (ed) over the handed-off terminal is committed")
        else:
            fail(
                "commit: a message written by a real interactive editor (ed) over the handed-off terminal is committed",
                "log=%r rc=%d" % (log_out, log_rc),
            )

    # --- leaving a diff: q and Escape back out, only the outline's q quits --
    #
    # One unstaged change is all this needs. The point is the key, not the
    # diff: `q`/`Escape` inside an open diff used to quit the whole program,
    # which is the one place a reader stepping through diffs gets surprised
    # (GIT_client.m31's `handle_diff_key`). The session's own exit code at
    # the end proves the outline's `q` still quits -- `Session.quit` sends
    # it and waits, and a process that ignored it would be killed instead
    # and report a nonzero code.
    fx10 = make_fixture(root, "diffexit")
    with open(os.path.join(fx10, "f.txt"), "w") as f:
        f.write("a\nb\n")
    git(fx10, "add", "-A", env=GIT_ENV)
    git(fx10, "commit", "-q", "-m", "first", env=GIT_ENV)
    with open(os.path.join(fx10, "f.txt"), "w") as f:
        f.write("a\nB\n")
    # rows: untracked(0), unstaged(1): M f.txt -> row1 unstaged section,
    # row2 M f.txt.
    s10 = Session(binpath, fx10)
    s10.send("j")
    s10.send("j")
    out = s10.send("d")
    if b"diff: M  f.txt" in out and b"+B" in out:
        ok("diff exit: d opens the diff (setup)")
    else:
        fail("diff exit: d opens the diff (setup)", repr(out))
    out = s10.send("q")
    if s10.proc.poll() is None and b"Unstaged changes" in out and b"diff: M  f.txt" not in out:
        ok("diff exit: q closes the diff and returns to the outline instead of quitting")
    else:
        fail("diff exit: q closes the diff and returns to the outline instead of quitting", "alive=%s out=%r" % (s10.proc.poll() is None, out))
    out = s10.send("d")
    if b"diff: M  f.txt" in out:
        ok("diff exit: the diff reopens after q")
    else:
        fail("diff exit: the diff reopens after q", repr(out))
    # A lone ESC is a whole key only once nothing follows it -- the reader
    # resolves that with a timeout (lib/term.m31's `Decoder.flush`), so give
    # it a longer drain than a printable key needs.
    out = s10.send("\x1b")
    out += s10.drain(0.8)
    if s10.proc.poll() is None and b"Unstaged changes" in out and b"diff: M  f.txt" not in out:
        ok("diff exit: Escape closes the diff and returns to the outline instead of quitting")
    else:
        fail("diff exit: Escape closes the diff and returns to the outline instead of quitting", "alive=%s out=%r" % (s10.proc.poll() is None, out))
    rc = s10.quit()
    if rc == 0:
        ok("diff exit: q in the outline still quits cleanly (exit 0)")
    else:
        fail("diff exit: q in the outline still quits cleanly (exit 0)", "rc=%r" % rc)

    # --- hunk-level staging from inside the diff view ------------------------
    #
    # One file, two hunks (lines 3 and 27 of 30). `d` opens the unstaged diff
    # with the cursor on hunk 0's header; `s` stages exactly that hunk, so git
    # reports the file partially staged (`MM`) and the view stays open on the
    # one hunk that is left. Then from the staged side: `u` on its only hunk
    # unstages it again and, with nothing left to show, the view closes back
    # to the outline. Real `git diff --cached` is the oracle for which hunk
    # went where; `test_gitui.sh`'s "gitui hunk:" checks compare the index
    # blob itself against `git apply --cached`.
    fx11 = make_fixture(root, "hunkstage")
    with open(os.path.join(fx11, "f.txt"), "w") as f:
        f.write("".join("line %d\n" % i for i in range(1, 31)))
    git(fx11, "add", "-A", env=GIT_ENV)
    git(fx11, "commit", "-q", "-m", "base", env=GIT_ENV)
    with open(os.path.join(fx11, "f.txt"), "w") as f:
        f.write("".join(("THREE\n" if i == 3 else "TWENTY-SEVEN\n" if i == 27 else "line %d\n" % i) for i in range(1, 31)))

    # rows: untracked(0), unstaged section(1): M f.txt, staged(0), commits --
    # row0 untracked, row1 unstaged section, row2 M f.txt.
    s11 = Session(binpath, fx11)
    s11.send("j")
    s11.send("j")  # row2: M f.txt (unstaged)
    out = s11.send("d")  # open its diff; cursor on hunk 0's @@ header
    if b"-line 3" in out and b"+THREE" in out and b"+TWENTY-SEVEN" in out and b"stage hunk" in out:
        ok("hunk: the unstaged diff shows both hunks and the footer offers 's stage hunk'")
    else:
        fail("hunk: the unstaged diff shows both hunks and the footer offers 's stage hunk'", repr(out))
    out = s11.send("s")  # stage hunk 0 only
    status_out, _, _ = git(fx11, "status", "--short")
    cached, _, _ = git(fx11, "diff", "--cached", "--no-color", "--", "f.txt")
    if status_out == "MM f.txt" and "+THREE" in cached and "+TWENTY-SEVEN" not in cached:
        ok("hunk: 's' in the diff view stages only the hunk under the cursor (git: MM, --cached has hunk 0 alone)")
    else:
        fail("hunk: 's' in the diff view stages only the hunk under the cursor", "status=%r cached=%r" % (status_out, cached))
    if b"+TWENTY-SEVEN" in out and b"staged hunk 1 of f.txt" in out:
        ok("hunk: the view stays open on the remaining hunk and says what it did")
    else:
        fail("hunk: the view stays open on the remaining hunk and says what it did", repr(out))
    s11.send("\x7f")  # back to the outline
    # rows now: untracked(0), unstaged(1): M f.txt, staged(1): M f.txt --
    # row0 untracked, row1 unstaged section, row2 M f.txt, row3 staged
    # section, row4 M f.txt (staged).
    s11.send("j")
    s11.send("j")  # row4: the staged M f.txt
    s11.send("d")  # its diff: HEAD vs index, one hunk (THREE)
    out = s11.send("u")  # unstage that only hunk: nothing left, view closes
    status_out, _, _ = git(fx11, "status", "--short")
    if status_out == " M f.txt" and b"Unstaged changes" in out and b"unstaged hunk 1 of f.txt" in out:
        ok("hunk: 'u' on a staged diff's only hunk unstages it and closes the empty view (git: ' M')")
    else:
        fail("hunk: 'u' on a staged diff's only hunk unstages it and closes the empty view", "status=%r out=%r" % (status_out, out))
    s11.quit()

    # --- discard: `x` asks, `y` discards, anything else keeps -----------------
    #
    # The on-disk effect of each discard kind is checked against real git by
    # test_discard_amend.sh; what a pty adds is the prompt itself: that `x`
    # alone changes nothing, that a non-`y` key cancels, and that `y` goes
    # through to the same `discard_path` -- with the status line's own words
    # as the evidence of which branch ran.
    fx10 = make_fixture(root, "discard")
    with open(os.path.join(fx10, "a.txt"), "w") as f:
        f.write("one\n")
    git(fx10, "add", "-A", env=GIT_ENV)
    git(fx10, "commit", "-q", "-m", "first", env=GIT_ENV)
    with open(os.path.join(fx10, "a.txt"), "w") as f:
        f.write("one\nchanged\n")
    # rows: untracked(0), unstaged section(1): M a.txt -> row0 untracked,
    # row1 unstaged section, row2 M a.txt.
    s10 = Session(binpath, fx10)
    s10.send("j")
    s10.send("j")  # row2: M a.txt
    out = s10.send("x")
    if b"discard changes to a.txt?" in out:
        ok("discard: x opens a confirmation naming the path, and changes nothing yet")
    else:
        fail("discard: x opens a confirmation naming the path", repr(out))
    out = s10.send("n")  # any key but y cancels
    got, _, _ = git(fx10, "status", "--short")
    if b"discard cancelled" in out and got == " M a.txt":
        ok("discard: a key other than y cancels, the modification is still there")
    else:
        fail("discard: a key other than y cancels", "out=%r status=%r" % (out, got))
    s10.send("x")
    out = s10.send("y")
    got, _, _ = git(fx10, "status", "--short")
    with open(os.path.join(fx10, "a.txt")) as f:
        a_now = f.read()
    if b"discarded changes to a.txt" in out and got == "" and a_now == "one\n":
        ok("discard: y restores the index's blob, git status --short is clean afterward")
    else:
        fail("discard: y restores the index's blob", "out=%r status=%r a.txt=%r" % (out, got, a_now))
    s10.quit()

    # --- amend: `c`, `A`, `f` replaces HEAD --------------------------------
    fx11 = make_fixture(root, "amend")
    with open(os.path.join(fx11, "a.txt"), "w") as f:
        f.write("one\n")
    git(fx11, "add", "-A", env=GIT_ENV)
    git(fx11, "commit", "-q", "-m", "first", env=GIT_ENV)
    before, _, _ = git(fx11, "rev-parse", "HEAD")
    with open(os.path.join(fx11, "b.txt"), "w") as f:
        f.write("two\n")
    git(fx11, "add", "-A", env=GIT_ENV)
    s11 = Session(binpath, fx11)
    s11.send("c")
    out = s11.send("A")
    if b"amend HEAD" in out and b"amending " in out:
        ok("amend: c then A turns the commit overlay into an amend, naming HEAD")
    else:
        fail("amend: c then A turns the commit overlay into an amend", repr(out))
    out = s11.send("f")
    s11.quit()
    after, _, _ = git(fx11, "rev-parse", "HEAD")
    count, _, _ = git(fx11, "rev-list", "--count", "HEAD")
    subject, _, _ = git(fx11, "log", "-1", "--format=%s")
    status_out, _, _ = git(fx11, "status", "--short")
    tree_has_b, _, rc_b = git(fx11, "cat-file", "-e", "HEAD:b.txt")
    if b"HEAD is now" in out and after != before and count == "1" and subject == "first" and status_out == "" and rc_b == 0:
        ok("amend: f replaces HEAD (still one commit, same message, b.txt now in its tree, nothing left staged)")
    else:
        fail(
            "amend: f replaces HEAD",
            "out=%r before=%s after=%s count=%s subject=%r status=%r b_rc=%d" % (out, before, after, count, subject, status_out, rc_b),
        )

    # --- branches: `b` then `c` checks out the branch under the cursor -----
    fx12 = make_fixture(root, "checkout-branch")
    with open(os.path.join(fx12, "a.txt"), "w") as f:
        f.write("one\n")
    git(fx12, "add", "-A", env=GIT_ENV)
    git(fx12, "commit", "-q", "-m", "first", env=GIT_ENV)
    git(fx12, "checkout", "-q", "-b", "feature")
    with open(os.path.join(fx12, "a.txt"), "w") as f:
        f.write("two\n")
    with open(os.path.join(fx12, "f.txt"), "w") as f:
        f.write("only on feature\n")
    git(fx12, "add", "-A", env=GIT_ENV)
    git(fx12, "commit", "-q", "-m", "second", env=GIT_ENV)
    git(fx12, "checkout", "-q", "main")

    # rows: untracked(0) unstaged(1) staged(2) commits(3) its commit(4, collapsed)
    # branches(5) feature(6) main(7) -- branches sort by name.
    s12 = Session(binpath, fx12)
    out = s12.send("jjjjj")  # row5: the Branches section
    out += s12.send("j")  # row6: feature (screen updates are diffs, so gather both)
    if b"Branches (2)" in out and b"feature" in out and b"second" in out:
        ok("branches: the outline shows a Branches section listing feature and its tip subject")
    else:
        fail("branches: the outline shows a Branches section listing feature and its tip subject", repr(out))
    out = s12.send("b")
    if b"check out" in out.lower() or b"checkout" in out.lower():
        ok("branches: `b` opens the branch which-key overlay")
    else:
        fail("branches: `b` opens the branch which-key overlay", repr(out))
    out = s12.send("c")
    if b"switched to feature" in out:
        ok("branches: `c` reports the switch in the message line")
    else:
        fail("branches: `c` reports the switch in the message line", repr(out))
    s12.quit()
    head_out, _, _ = git(fx12, "symbolic-ref", "HEAD")
    status_out, _, _ = git(fx12, "status", "--short")
    with open(os.path.join(fx12, "a.txt")) as f:
        a_txt = f.read()
    if head_out == "refs/heads/feature" and status_out == "" and a_txt == "two\n" and os.path.exists(os.path.join(fx12, "f.txt")):
        ok("branches: after `b` `c`, git agrees -- HEAD on feature, status clean, files match")
    else:
        fail("branches: after `b` `c`, git agrees", "head=%r status=%r a=%r" % (head_out, status_out, a_txt))

    # a dirty file in the way: refused, message shown, nothing changes
    with open(os.path.join(fx12, "a.txt"), "w") as f:
        f.write("dirty\n")
    s12 = Session(binpath, fx12)
    s12.send("j" * 40)  # the cursor stops on the last row: main, the last branch
    out = s12.send("b")
    out += s12.send("c")
    if b"refused" in out:
        ok("branches: a dirty file in the way is refused with a reason in the message line")
    else:
        fail("branches: a dirty file in the way is refused with a reason in the message line", repr(out))
    s12.quit()
    head_out, _, _ = git(fx12, "symbolic-ref", "HEAD")
    with open(os.path.join(fx12, "a.txt")) as f:
        a_txt = f.read()
    if head_out == "refs/heads/feature" and a_txt == "dirty\n":
        ok("branches: the refused checkout left HEAD and the dirty file alone")
    else:
        fail("branches: the refused checkout left HEAD and the dirty file alone", "head=%r a=%r" % (head_out, a_txt))

    # --- push: P opens the which-key, p pushes over smart HTTP ----------------
    #
    # A real `git http-backend` served from a thread of this very script, as a
    # CGI behind `http.server`; the bare repository behind it is the oracle.
    import http.server
    import threading

    backend = os.path.join(subprocess.run(["git", "--exec-path"], capture_output=True, text=True).stdout.strip(), "git-http-backend")
    if not os.path.exists(backend):
        print("gitui pty: push check skipped, no git-http-backend", file=sys.stderr)
    else:
        ps_root = os.path.join(root, "push-e2e")
        os.makedirs(os.path.join(ps_root, "www", "cgi-bin"))
        os.makedirs(os.path.join(ps_root, "srv"))
        ps_srv = os.path.join(ps_root, "srv", "repo.git")
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", ps_srv], check=True)
        git(ps_srv, "config", "http.receivepack", "true")
        wrapper = os.path.join(ps_root, "www", "cgi-bin", "git-http-backend")
        with open(wrapper, "w") as f:
            f.write("#!/bin/sh\nexport GIT_PROJECT_ROOT=%s\nexport GIT_HTTP_EXPORT_ALL=1\nexec %s\n" % (os.path.join(ps_root, "srv"), backend))
        os.chmod(wrapper, 0o755)

        class PushHandler(http.server.CGIHTTPRequestHandler):
            cgi_directories = ["/cgi-bin"]

            def log_message(self, fmt, *args):
                pass

        import functools

        httpd = http.server.ThreadingHTTPServer(
            ("127.0.0.1", 0), functools.partial(PushHandler, directory=os.path.join(ps_root, "www"))
        )
        ps_port = httpd.server_address[1]
        threading.Thread(target=httpd.serve_forever, daemon=True).start()

        fx_push = make_fixture(root, "push-client")
        with open(os.path.join(fx_push, "a.txt"), "w") as f:
            f.write("one\n")
        git(fx_push, "add", "-A", env=GIT_ENV)
        git(fx_push, "commit", "-q", "-m", "first", env=GIT_ENV)
        git(fx_push, "remote", "add", "origin", "http://127.0.0.1:%d/cgi-bin/git-http-backend/repo.git" % ps_port)

        sp = Session(binpath, fx_push)
        out = sp.send("P")
        if b"push" in out and b"fast-forward" in out:
            ok("push: P opens the push which-key overlay")
        else:
            fail("push: P opens the push which-key overlay", repr(out))
        sp.send("\x1b")
        time.sleep(0.3)
        sp.drain()
        before, _, _ = git(ps_srv, "rev-parse", "-q", "--verify", "refs/heads/main")
        if before == "":
            ok("push: Escape closes the overlay and pushes nothing")
        else:
            fail("push: Escape closes the overlay and pushes nothing", "server main = %r" % before)
        sp.send("P")
        sp.send("p")
        time.sleep(1.0)
        sp.drain()
        want, _, _ = git(fx_push, "rev-parse", "HEAD")
        got, _, _ = git(ps_srv, "rev-parse", "-q", "--verify", "refs/heads/main")
        fsck_out, _, fsck_rc = git(ps_srv, "fsck", "--full")
        if want != "" and got == want and fsck_rc == 0:
            ok("push: P then p pushes the current branch; the server's main equals HEAD and fsck is clean")
        else:
            fail("push: P then p pushes the current branch", "want=%r got=%r fsck=%r" % (want, got, fsck_out))
        rc = sp.quit()
        if rc == 0:
            ok("push: the client is still responsive and exits cleanly after a push")
        else:
            fail("push: the client is still responsive and exits cleanly after a push", "returncode=%r" % rc)

        # A second commit, pushed again: only a fast-forward goes through.
        with open(os.path.join(fx_push, "a.txt"), "a") as f:
            f.write("two\n")
        git(fx_push, "add", "-A", env=GIT_ENV)
        git(fx_push, "commit", "-q", "-m", "second", env=GIT_ENV)
        sp2 = Session(binpath, fx_push)
        sp2.send("P")
        sp2.send("p")
        time.sleep(1.0)
        sp2.drain()
        want, _, _ = git(fx_push, "rev-parse", "HEAD")
        got, _, _ = git(ps_srv, "rev-parse", "refs/heads/main")
        if got == want:
            ok("push: a second commit fast-forwards the server's main")
        else:
            fail("push: a second commit fast-forwards the server's main", "want=%r got=%r" % (want, got))
        sp2.quit()

        # --- pull: F opens the which-key, p fast-forwards from origin ---------
        ps_url = "http://127.0.0.1:%d/cgi-bin/git-http-backend/repo.git" % ps_port
        pl_client = os.path.join(root, "pull-client")
        pl_other = os.path.join(root, "pull-other")
        subprocess.run(["git", "clone", "-q", ps_url, pl_client], check=True)
        subprocess.run(["git", "clone", "-q", ps_url, pl_other], check=True)

        def other_commit(name, text):
            with open(os.path.join(pl_other, name), "w") as f:
                f.write(text)
            git(pl_other, "add", "-A", env=GIT_ENV)
            git(pl_other, "commit", "-q", "-m", "upstream " + name, env=GIT_ENV)
            git(pl_other, "push", "-q", "origin", "main", env=GIT_ENV)

        other_commit("up1.txt", "from upstream\n")
        old_head, _, _ = git(pl_client, "rev-parse", "HEAD")
        sl = Session(binpath, pl_client)
        out = sl.send("F")
        if b"pull" in out and b"fast-forward" in out:
            ok("pull: F opens the pull which-key overlay")
        else:
            fail("pull: F opens the pull which-key overlay", repr(out))
        sl.send("\x1b")
        time.sleep(0.3)
        sl.drain()
        now, _, _ = git(pl_client, "rev-parse", "HEAD")
        if now == old_head:
            ok("pull: Escape closes the overlay and pulls nothing")
        else:
            fail("pull: Escape closes the overlay and pulls nothing", "head moved to %r" % now)

        # A dirty tree is refused: nothing moves, the edit survives.
        with open(os.path.join(pl_client, "a.txt"), "a") as f:
            f.write("local edit\n")
        sl.send("F")
        sl.send("p")
        time.sleep(1.0)
        sl.drain()
        now, _, _ = git(pl_client, "rev-parse", "HEAD")
        with open(os.path.join(pl_client, "a.txt")) as f:
            edited = f.read().endswith("local edit\n")
        if now == old_head and edited and not os.path.exists(os.path.join(pl_client, "up1.txt")):
            ok("pull: F then p on a dirty tree is refused; HEAD and the edit are untouched")
        else:
            fail("pull: F then p on a dirty tree is refused", "head=%r edited=%r" % (now, edited))

        git(pl_client, "checkout", "--", "a.txt", env=GIT_ENV)
        sl.send("F")
        sl.send("p")
        time.sleep(1.5)
        sl.drain()
        want, _, _ = git(pl_other, "rev-parse", "HEAD")
        got, _, _ = git(pl_client, "rev-parse", "HEAD")
        status_out, _, _ = git(pl_client, "status", "--porcelain")
        fsck_out, _, fsck_rc = git(pl_client, "fsck", "--full")
        if got == want and os.path.exists(os.path.join(pl_client, "up1.txt")) and status_out == "" and fsck_rc == 0:
            ok("pull: F then p fast-forwards HEAD, the branch and the working tree to origin's tip; status and fsck are clean")
        else:
            fail("pull: F then p fast-forwards", "want=%r got=%r status=%r fsck=%r" % (want, got, status_out, fsck_out))
        rc = sl.quit()
        if rc == 0:
            ok("pull: the client is still responsive and exits cleanly after a pull")
        else:
            fail("pull: the client is still responsive and exits cleanly after a pull", "returncode=%r" % rc)

        # Diverged: a local commit plus a new upstream one is refused.
        with open(os.path.join(pl_client, "mine.txt"), "w") as f:
            f.write("mine\n")
        git(pl_client, "add", "-A", env=GIT_ENV)
        git(pl_client, "commit", "-q", "-m", "mine", env=GIT_ENV)
        local_head, _, _ = git(pl_client, "rev-parse", "HEAD")
        other_commit("up2.txt", "more upstream\n")
        sl2 = Session(binpath, pl_client)
        sl2.send("F")
        sl2.send("p")
        time.sleep(1.5)
        sl2.drain()
        now, _, _ = git(pl_client, "rev-parse", "HEAD")
        if now == local_head and not os.path.exists(os.path.join(pl_client, "up2.txt")):
            ok("pull: a diverged branch is refused; HEAD and the working tree are untouched")
        else:
            fail("pull: a diverged branch is refused", "head=%r want=%r" % (now, local_head))
        sl2.quit()
        httpd.shutdown()

    # --- overlays: the command log (@), key help (?), stage/unstage all (S, U),
    # search (/ n N), refresh (g, R) and the fuzzy branch picker. These check
    # `Session.text()`, the emulated screen, rather than the byte stream: the
    # renderer writes only changed cells, which splits a message in pieces. ---

    def commit_file(fx, name, text, message):
        with open(os.path.join(fx, name), "w") as f:
            f.write(text)
        git(fx, "add", "-A", env=GIT_ENV)
        git(fx, "commit", "-q", "-m", message, env=GIT_ENV)

    def check(name, condition, detail=""):
        if condition:
            ok(name)
        else:
            fail(name, detail)

    # S stages everything, U unstages everything; git is the oracle both ways.
    fx20 = make_fixture(root, "stage-all")
    commit_file(fx20, "a.txt", "one\n", "first")
    commit_file(fx20, "gone.txt", "bye\n", "second")
    with open(os.path.join(fx20, "a.txt"), "a") as f:
        f.write("changed\n")
    os.remove(os.path.join(fx20, "gone.txt"))
    with open(os.path.join(fx20, "new.txt"), "w") as f:
        f.write("brand new\n")
    s20 = Session(binpath, fx20)
    s20.send("S")
    got, _, _ = git(fx20, "status", "--short")
    fsck_out, _, _ = git(fx20, "fsck", "--strict")
    check(
        "stage-all: S stages the modified, deleted and untracked files (git status --short agrees, fsck clean)",
        got == "M  a.txt\nD  gone.txt\nA  new.txt" and "error" not in fsck_out,
        "status=%r fsck=%r" % (got, fsck_out),
    )
    s20.send("@")
    check("command log: S is logged as one 'stage-all' line", "stage-all" in s20.text(), s20.text())
    s20.send("\x1b")
    s20.send("U")
    got, _, _ = git(fx20, "status", "--short")
    fsck_out, _, _ = git(fx20, "fsck", "--strict")
    check(
        "unstage-all: U unstages everything (git status --short agrees, fsck clean)",
        got == " M a.txt\n D gone.txt\n?? new.txt" and "error" not in fsck_out,
        "status=%r fsck=%r" % (got, fsck_out),
    )
    s20.send("@")
    check("command log: U is logged as one 'unstage-all' line, after the stage-all line", "unstage-all" in s20.text(), s20.text())
    s20.quit()

    # @ shows one line per write operation, newest last; empty at first.
    fx21 = make_fixture(root, "command-log")
    commit_file(fx21, "a.txt", "one\n", "first")
    with open(os.path.join(fx21, "a.txt"), "a") as f:
        f.write("more\n")
    editor_log = os.path.join(root, "editor-log.sh")
    write_editor_script(editor_log, "logged commit")
    s21 = Session(binpath, fx21, env=env_with_editor(editor_log))
    s21.send("@")
    check("command log: @ opens the log, empty before any write operation", "no write operations yet" in s21.text() and "command log" in s21.text(), s21.text())
    s21.send("\x1b")
    s21.send("jj")  # untracked(0) unstaged(1) a.txt(2)
    s21.send("s")
    s21.send("@")
    check("command log: staging a file logs 'stage a.txt'", "stage a.txt" in s21.text(), s21.text())
    s21.send("\x1b")
    s21.send("c")
    s21.send("e")
    time.sleep(0.3)
    s21.drain()
    s21.send("@")
    head_short, _, _ = git(fx21, "rev-parse", "--short=7", "HEAD")
    text = s21.text()
    check(
        "command log: a commit logs 'update-ref refs/heads/main <old>..<new>' ending at the new HEAD",
        "update-ref refs/heads/main" in text and ".." + head_short in text and "stage a.txt" in text,
        "head=%s text=%s" % (head_short, text),
    )
    s21.send("k")
    s21.send("g")
    s21.send("G")
    check("command log: k, g and G scroll without leaving the overlay", "command log" in s21.text(), s21.text())
    s21.send("\x1b")
    check("command log: Escape closes it", "command log" not in s21.text(), s21.text())
    rc = s21.quit()
    check("command log: after Escape, q quits the client", rc == 0, "rc=%r" % rc)

    # ? lists the key table; Escape closes it.
    fx22 = make_fixture(root, "key-help")
    commit_file(fx22, "a.txt", "one\n", "first")
    s22 = Session(binpath, fx22)
    check("key help: the footer advertises '?' and '@'", "? help" in s22.text() and "@ log" in s22.text(), s22.text())
    s22.send("?")
    text = s22.text()
    check(
        "key help: ? lists the bindings, generated from the key table",
        "keys" in text and "outline" in text and "stage everything" in text,
        text,
    )
    check("key help: the footer shows the overlay's own keys while it is open", "scroll" in text.splitlines()[-2] and "close" in text.splitlines()[-2], text)
    s22.send("j")
    s22.send("j")
    s22.send("k")
    s22.send("\x1b")
    check("key help: Escape closes it", "stage everything" not in s22.text(), s22.text())
    rc = s22.quit()
    check("key help: after Escape, q quits the client", rc == 0, "rc=%r" % rc)
    s22b = Session(binpath, fx22)
    s22b.send("?")
    s22b.send("q")  # q closes the help overlay rather than quitting the client
    still_running = s22b.proc.poll() is None
    rc = s22b.quit()
    check("key help: q closes the overlay first; a second q quits", still_running and rc == 0, "running=%r rc=%r" % (still_running, rc))

    # / search with n / N, case-smart, in the log (commit rows) and the outline.
    fx23 = make_fixture(root, "search")
    commit_file(fx23, "a.txt", "1\n", "needle one")
    commit_file(fx23, "b.txt", "2\n", "Needle two")
    commit_file(fx23, "c.txt", "3\n", "other thing")
    s23 = Session(binpath, fx23)

    s23.send("/")
    check("search: / opens a prompt on the bottom row of the body", "/_" in s23.text(), s23.text())
    s23.send("needle")
    s23.send("\r")
    check("search: a lower-case query ignores case; two matches, the first is the newer commit", "/needle: match 1 of 2" in s23.text(), s23.text())
    s23.send("n")
    check("search: n moves to the next match", "/needle: match 2 of 2" in s23.text(), s23.text())
    s23.send("n")
    check("search: n wraps round from the last match to the first", "/needle: match 1 of 2" in s23.text(), s23.text())
    s23.send("N")
    check("search: N moves back, wrapping", "/needle: match 2 of 2" in s23.text(), s23.text())
    s23.send("N")
    check("search: N then steps back to the first match", "/needle: match 1 of 2" in s23.text(), s23.text())
    s23.send("/")
    s23.send("Needle")
    s23.send("\r")
    check("search: a capital in the query makes it case-sensitive", "/Needle: match 1 of 1" in s23.text(), s23.text())
    s23.send("/")
    s23.send("zzz")
    s23.send("\r")
    check("search: a query with no match says so", "/zzz: no match" in s23.text(), s23.text())
    s23.send("/")
    s23.send("abc")
    s23.send("\x7f\x7f\x7f")
    s23.send("two")
    s23.send("\r")
    check("search: backspace erases typed characters", "/two: match 1 of 1" in s23.text(), s23.text())
    s23.quit()
    s23b = Session(binpath, fx23)
    s23b.send("/")
    s23b.send("zzz")
    s23b.send("\x1b")
    check("search: Escape closes the prompt", "/zzz_" not in s23b.text(), s23b.text())
    s23b.send("n")
    check("search: Escape did not remember the query", "press / and type" in s23b.text(), s23b.text())
    s23b.quit()

    # g and R refresh; r opens the rebase menu.
    fx24 = make_fixture(root, "refresh")
    commit_file(fx24, "a.txt", "one\n", "first")
    s24 = Session(binpath, fx24)
    with open(os.path.join(fx24, "via_g.txt"), "w") as f:
        f.write("x\n")
    s24.send("g")
    check("refresh: g re-reads the repository and shows a file created behind its back", "via_g.txt" in s24.text(), s24.text())
    with open(os.path.join(fx24, "via_upper_R.txt"), "w") as f:
        f.write("x\n")
    s24.send("R")
    check("refresh: R still refreshes", "via_upper_R.txt" in s24.text(), s24.text())
    with open(os.path.join(fx24, "via_lower_r.txt"), "w") as f:
        f.write("x\n")
    s24.send("r")
    check("refresh: r opens the rebase menu, not a refresh", "autosquash" in s24.text(), s24.text())
    s24.send("\x1b")
    s24.send("g")
    check("refresh: g then picks it up", "via_lower_r.txt" in s24.text(), s24.text())
    s24.quit()

    # The generic fuzzy picker, through the branch overlay's `/`.
    fx25 = make_fixture(root, "picker")
    commit_file(fx25, "a.txt", "one\n", "first")
    git(fx25, "branch", "feature/login")
    git(fx25, "branch", "feature/logout")
    git(fx25, "checkout", "-q", "feature/login")
    s25 = Session(binpath, fx25)
    s25.send("b")
    s25.send("/")
    text = s25.text()
    check(
        "picker: b then / opens the fuzzy picker listing every branch",
        "check out a branch" in text and "> _" in text and "feature/logout" in text and " main" in text,
        text,
    )
    s25.send("zzz")
    check("picker: a filter nothing matches shows so", "(nothing matches)" in s25.text(), s25.text())
    s25.send("\r")
    head, _, _ = git(fx25, "symbolic-ref", "--short", "HEAD")
    check("picker: enter with nothing matching chooses nothing and keeps the picker open", head == "feature/login" and "> zzz_" in s25.text(), "head=%r" % head)
    s25.send("\x7f\x7f\x7f")
    s25.send("lgou")
    text = s25.text()
    check("picker: typing a subsequence ('lgou') narrows the list to feature/logout", "> lgou_" in text and "(nothing matches)" not in text, text)
    s25.send("\r")
    head, _, _ = git(fx25, "symbolic-ref", "--short", "HEAD")
    status_out, _, _ = git(fx25, "status", "--short")
    fsck_out, _, _ = git(fx25, "fsck", "--strict")
    check(
        "picker: enter checks out the picked branch (git: HEAD on feature/logout, clean, fsck clean)",
        head == "feature/logout" and status_out == "" and "error" not in fsck_out,
        "head=%r status=%r fsck=%r" % (head, status_out, fsck_out),
    )
    s25.send("@")
    check("command log: a checkout logs 'checkout feature/logout'", "checkout feature/logout" in s25.text(), s25.text())
    s25.send("\x1b")
    s25.send("b")
    s25.send("/")
    s25.send("\x1b")
    check("picker: Escape closes the picker", "check out a branch" not in s25.text(), s25.text())
    head2, _, _ = git(fx25, "symbolic-ref", "--short", "HEAD")
    rc = s25.quit()
    check("picker: Escape cancels and changes nothing; the stack is empty so q quits", head2 == "feature/logout" and rc == 0, "head=%r rc=%r" % (head2, rc))

    import pty_blame_undo

    pty_blame_undo.run(Context(binpath, root, Session, make_fixture, git, GIT_ENV, ok, fail))

    return failures


if __name__ == "__main__":
    sys.exit(1 if main() > 0 else 0)
