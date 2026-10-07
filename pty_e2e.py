#!/usr/bin/env python3
"""Drive the compiled `ourgitui` binary under a real pty, against disposable
git fixtures this script builds and destroys itself -- the same discipline
`apps/git/test.sh`/`test_write.sh` already use for the write-path work, and
`apps/git/design.md`'s own "Safety" section names for this client
specifically: never a real repository, real `git` as the oracle throughout.

Run from anywhere:

    python3 apps/git/pty_e2e.py <ourgitui-binary> <scratch-dir>

`<scratch-dir>` is created fresh (and removed first if it already exists) --
`test_gitui.sh` passes it a directory under its own `mktemp -d`, never
anything resembling a real repository.

Every `ok`/`FAIL` line this prints is one check; the exit code is the number
of failures, so `test_gitui.sh` can both grep for `FAIL` and trust `$?`. This
is the "drive it under a pty against a disposable fixture, oracle-checked"
half of the client's test obligations (`apps/git/design.md`, "how you'll know
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


class Session:
    """One `ourgitui` process on a pty, in one fixture directory."""

    def __init__(self, binpath, fixture, env=None):
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
        return out

    def send(self, keys):
        os.write(self.master, keys.encode())
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


def make_fixture(root, name):
    fx = os.path.join(root, name)
    os.makedirs(fx)
    subprocess.run(["git", "init", "-q", "-b", "main", "."], cwd=fx, check=True)
    return fx


def write_editor_script(path, message):
    """A stand-in `$EDITOR`: overwrite the message file it is given with a
    fixed line and exit 0. `e` now actually runs `$EDITOR` via `os.run` and
    waits for it, so the pty tests below drive a real (if trivial) child
    process rather than editing `COMMIT_EDITMSG` out of band from Python --
    the same thing `apps/git/test_gitui.sh`'s own stand-in editors do for the
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
    # it -- see `gitclient.m31`'s own header, "launching `$EDITOR`, and the
    # terminal handoff that takes" -- so this drives that for real, with a
    # stand-in editor standing in for `$EDITOR` exactly as
    # `apps/git/test_gitui.sh`'s own non-pty checks do for every `os.run`
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
    # exact "stage a file, modify it further" scenario `apps/git/design.md`
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
    # (gitclient.m31's `State.handle_enter`).
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
    # cached per commit -- gitclient.m31's `ensure_commit_changes`), and its
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
    # (gitclient.m31's `handle_diff_key`). The session's own exit code at
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

    return failures


if __name__ == "__main__":
    sys.exit(1 if main() > 0 else 0)
