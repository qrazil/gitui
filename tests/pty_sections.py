#!/usr/bin/env python3
"""Sections and the statusline under a real pty.

    python3 tests/pty_sections.py <mgit-binary> <scratch-dir>

Disposable fixtures, real `git` as the oracle where there is one:

  * `[` / `]` between the outline's section headers (seen through what a
    following Enter or Tab folds), `{` / `}`, Tab on a section and on a leaf,
    `-` and `+`, and the fold list kept in `git config mgit.collapsed`;
  * the diff view: `[` / `]` between hunks (seen through what `s` stages, git
    is the oracle), Tab and `-` / `+` folding hunks, `{` / `}` between files;
  * the statusline on the frame's top border: ahead and behind, the stash
    count, a detached HEAD, a merge under way with its conflicts, an unborn
    branch, a narrow terminal, and an update on the auto-refresh;
  * the `i` overview and what Enter opens from each line.
"""
import fcntl
import os
import shutil
import signal
import struct
import subprocess
import sys
import termios
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pty_e2e  # noqa: E402
from pty_e2e import CLIENT_ENV, GIT_ENV, Screen, Session, git, make_fixture  # noqa: E402

failures = 0


def check(name, condition, detail=""):
    global failures
    if condition:
        print("ok   " + name, flush=True)
    else:
        failures += 1
        print("FAIL " + name + ": " + detail, flush=True)


BASE = 1700000000


def commit(fx, name, text, message, when):
    with open(os.path.join(fx, name), "w") as f:
        f.write(text)
    env = dict(GIT_ENV)
    env["GIT_AUTHOR_DATE"] = "%d +0000" % when
    env["GIT_COMMITTER_DATE"] = "%d +0000" % when
    git(fx, "add", "-A", env=env)
    git(fx, "commit", "-q", "-m", message, env=env)


def wait_for(session, predicate, timeout=4.0):
    end = time.time() + timeout
    while time.time() < end:
        session.drain(0.3)
        if predicate(session.text()):
            return True
    return predicate(session.text())


def top(s):
    """The statusline: the frame's top border row."""
    return s.text().split("\n")[0]


def has_row(text, content):
    """Is there a screen row whose text, inside the frame and the diff's
    border, is exactly `content`?"""
    for row in text.split("\n"):
        if row.strip("\u2502 ").rstrip("\u2502 ") == content:
            return True
    return False


def row_with(s, needle):
    for row in s.text().split("\n"):
        if needle in row:
            return row
    return ""


class SizedSession(Session):
    """A session on a pty of a given width: the winsize is set before the
    program starts, so its first frame is already that wide."""

    def __init__(self, binpath, fixture, cols, rows=24):
        import pty
        self.screen = Screen(rows=rows, cols=cols)
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.proc = subprocess.Popen([binpath, fixture], stdin=slave, stdout=slave, stderr=slave, cwd=fixture, env=CLIENT_ENV)
        os.close(slave)
        time.sleep(0.3)
        self.drain()


def main():
    if len(sys.argv) != 3:
        print("usage: pty_sections.py <mgit-binary> <scratch-dir>", file=sys.stderr)
        return 2
    binpath = os.path.abspath(sys.argv[1])
    root = os.path.abspath(sys.argv[2])
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(root)

    # ------------------------------------------------ the outline's sections
    fx = make_fixture(root, "outline")
    lines = "".join("line %d\n" % i for i in range(1, 61))
    commit(fx, "a.txt", lines, "first", BASE)
    commit(fx, "b.txt", "b\n", "second", BASE + 10)
    edited = lines.replace("line 3\n", "CHANGED 3\n")
    with open(os.path.join(fx, "a.txt"), "w") as f:
        f.write(edited)
    with open(os.path.join(fx, "b.txt"), "a") as f:
        f.write("more\n")
    with open(os.path.join(fx, "new.txt"), "w") as f:
        f.write("n\n")
    with open(os.path.join(fx, "new2.txt"), "w") as f:
        f.write("n\n")
    git(fx, "add", "b.txt")
    # untracked(2): new.txt new2.txt | unstaged(1): a.txt | staged(1): b.txt | commits(2) | branches(1)

    s = SizedSession(binpath, fx, 80)
    t = s.text()
    check("sections: the outline starts expanded", "▾ Untracked files (2)" in t and "▾ Unstaged changes (1)" in t, t)
    s.send("]")
    s.send("\r")  # Enter folds the section the cursor is on
    check("] moves to the next section header (Enter then folds Unstaged)", "▸ Unstaged changes (1)" in s.text() and "▾ Untracked files (2)" in s.text(), s.text())
    s.send("\r")
    s.send("]")
    s.send("\r")
    check("] again: Staged", "▸ Staged changes (1)" in s.text() and "▾ Unstaged changes (1)" in s.text(), s.text())
    s.send("\r")
    s.send("j")  # onto the staged file b.txt
    s.send("[")
    s.send("\r")
    check("[ from a file goes to its own section header first", "▸ Staged changes (1)" in s.text(), s.text())
    s.send("\r")
    s.send("[")
    s.send("\r")
    check("[ from a header goes to the one before", "▸ Unstaged changes (1)" in s.text() and "▾ Staged changes (1)" in s.text(), s.text())
    s.send("\r")
    s.send("[")
    s.send("[")
    check("[ at the first header says so", "already at the first section" in s.text(), s.text())
    # { and }: from the first header to the next section; from a file to the next file
    s.send("j")  # new.txt
    s.send("}")
    s.send("\r")
    check("} from the first file of a section goes to the next file (Enter on a file does nothing but stay)", "new2.txt" in s.text(), s.text())
    s.send("}")
    s.send("\r")
    check("} from the last file goes to the next section's header", "▸ Unstaged changes (1)" in s.text(), s.text())
    s.send("\r")
    s.send("{")
    s.send("\r")
    check("{ from a header goes to the previous row at that level", "▾ Untracked files (2)" in s.text() or "▸ Untracked files (2)" in s.text(), s.text())
    s.quit()

    # Tab, - and +
    git(fx, "config", "--unset-all", "mgit.collapsed")
    s = SizedSession(binpath, fx, 80)
    s.send("j")  # new.txt
    s.send("\t")
    t = s.text()
    check("Tab on a leaf folds its section and lands on it", "▸ Untracked files (2)" in t and "new.txt" not in t, t)
    s.send("\t")
    check("Tab on the section unfolds it again", "▾ Untracked files (2)" in s.text() and "new.txt" in s.text(), s.text())
    s.send("-")
    t = s.text()
    check("- folds every section", all(("▸ " + h) in t for h in ["Untracked files (2)", "Unstaged changes (1)", "Staged changes (1)", "Commits (2)", "Branches (1)"]) and "a.txt" not in t and "new.txt" not in t, t)
    s.send("+")
    t = s.text()
    check("+ unfolds them all", all(("▾ " + h) in t for h in ["Untracked files (2)", "Unstaged changes (1)", "Staged changes (1)", "Commits (2)", "Branches (1)"]) and "new.txt" in t, t)
    check("+ leaves a commit folded (Enter opens it)", "▸ " in row_with(s, "second") and "Files changed" not in s.text(), s.text())
    s.send("=")
    check("= is + too", "unfolded 0 rows" in s.text(), s.text())
    s.quit()

    # persisted folds
    got, _, _ = git(fx, "config", "--get", "mgit.collapsed")
    check("folds: nothing is kept when all are open", got == "", got)
    git(fx, "config", "--unset-all", "mgit.collapsed")
    s = SizedSession(binpath, fx, 80)
    s.send("\t")  # on the Untracked header: fold it
    s.send("]")
    s.send("]")
    s.send("\t")  # Staged
    s.quit()
    got, _, _ = git(fx, "config", "--get", "mgit.collapsed")
    check("folds: the folded sections are kept in mgit.collapsed", got == "staged,untracked", got)
    s = SizedSession(binpath, fx, 80)
    t = s.text()
    check("folds: they start folded in the next run", "▸ Untracked files (2)" in t and "▸ Staged changes (1)" in t and "▾ Unstaged changes (1)" in t, t)
    s.send("+")
    s.quit()
    got, _, rc = git(fx, "config", "--get", "mgit.collapsed")
    check("folds: unfolding everything unsets the key", got == "" and rc != 0, got)

    # ------------------------------------------------------ hunks in the diff
    fx2 = make_fixture(root, "hunks")
    body = "".join("line %d\n" % i for i in range(1, 61))
    commit(fx2, "a.txt", body, "first", BASE)
    commit(fx2, "b.txt", "one\n", "second", BASE + 10)
    edit = body.replace("line 3\n", "CHANGED 3\n").replace("line 30\n", "CHANGED 30\n").replace("line 57\n", "CHANGED 57\n")
    with open(os.path.join(fx2, "a.txt"), "w") as f:
        f.write(edit)
    with open(os.path.join(fx2, "b.txt"), "w") as f:
        f.write("two\n")
    # untracked(0) | unstaged(2): a.txt b.txt | ...
    s = SizedSession(binpath, fx2, 80, rows=30)
    s.send("jj")  # Unstaged header -> a.txt (cursor: 0 untracked, 1 unstaged, 2 a.txt)
    s.send("d")
    t = s.text()
    check("diff: three hunks open", t.count("@@ -") == 3 and "diff: M  a.txt" in t, t)
    s.send("]")
    s.send("]")
    s.send("s")
    got, _, _ = git(fx2, "diff", "--cached", "--unified=0", "a.txt")
    check("diff: ] ] then s stages exactly the third hunk", "CHANGED 57" in got and "CHANGED 30" not in got and "CHANGED 3\n" not in got + "\n", got)
    t = s.text()
    check("diff: the view shows the two hunks that are left", t.count("@@ -") == 2, t)
    s.send("[")
    s.send("[")
    s.send("[")
    check("diff: [ at the first hunk says so", "already at the first hunk" in s.text(), s.text())
    s.send("\t")
    t = s.text()
    check("diff: Tab folds the hunk under the cursor", "(7 lines)" in t and not has_row(t, "+CHANGED 3") and has_row(t, "+CHANGED 30"), t)
    s.send("\t")
    check("diff: Tab again unfolds it", has_row(s.text(), "+CHANGED 3") and "lines)" not in s.text(), s.text())
    s.send("-")
    t = s.text()
    check("diff: - folds every hunk", t.count("lines)") == 2 and "CHANGED" not in t, t)
    s.send("+")
    check("diff: + unfolds every hunk", has_row(s.text(), "+CHANGED 3") and has_row(s.text(), "+CHANGED 30") and "lines)" not in s.text(), s.text())
    s.send("-")
    s.send("]")
    s.send("s")
    got, _, _ = git(fx2, "diff", "--cached", "--unified=0", "a.txt")
    check("diff: a folded hunk is still staged whole (s on its header)", "CHANGED 30" in got and "CHANGED 57" in got and "CHANGED 3\n" not in got + "\n", got)
    s.send("q")
    t = s.text()
    check("diff: q is back at the outline", "diff:" not in t and "Unstaged changes" in t, t)
    s.send("j")
    s.send("d")
    check("diff: the second file's diff", "diff: M  b.txt" in s.text(), s.text())
    s.send("{")
    check("{ steps to the previous file of the list", "diff: M  a.txt" in s.text() or "no earlier file" in s.text(), s.text())
    s.send("}")
    check("} steps to the next file of the list", "diff: M  b.txt" in s.text(), s.text())
    s.send("}")
    check("} at the end of the list says so", "no later file in this list" in s.text(), s.text())
    s.send("q")
    s.quit()

    # a commit's files
    fx3 = make_fixture(root, "commitfiles")
    commit(fx3, "x.txt", "x\n", "base", BASE)
    with open(os.path.join(fx3, "y.txt"), "w") as f:
        f.write("y\n")
    with open(os.path.join(fx3, "x.txt"), "w") as f:
        f.write("x2\n")
    git(fx3, "add", "-A")
    git(fx3, "commit", "-q", "-m", "two files", env=GIT_ENV)
    s = SizedSession(binpath, fx3, 80)
    s.send("jjjj")  # untracked, unstaged, staged, commits -> the first commit row
    s.send("\r")  # unfold the commit; its Files changed section is open
    check("commit files: the commit lists its files", "x.txt" in s.text() and "y.txt" in s.text(), s.text())
    s.send("/")
    s.send("x.txt")
    s.send("\r")
    s.send("\r")  # Enter on a commit's file row opens its diff
    check("commit files: Enter on a file opens its diff", "diff: " in s.text() and "x.txt" in s.text(), s.text())
    s.send("}")
    check("commit files: } opens the commit's next file", "diff: " in s.text() and "y.txt" in s.text(), s.text())
    s.send("}")
    check("commit files: } at the end of the commit's files says so", "no later file in this list" in s.text(), s.text())
    s.send("{")
    check("commit files: { goes back", "diff: " in s.text() and "x.txt" in s.text(), s.text())
    s.send("q")
    s.quit()

    # -------------------------------------------------------- the statusline
    origin = os.path.join(root, "origin.git")
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", origin], check=True)
    seed = make_fixture(root, "seed")
    commit(seed, "a.txt", "1\n", "base", BASE)
    git(seed, "remote", "add", "origin", origin)
    git(seed, "push", "-q", "origin", "main", env=GIT_ENV)
    track = os.path.join(root, "track")
    subprocess.run(["git", "clone", "-q", origin, track], check=True)
    commit(track, "l1.txt", "l\n", "local one", BASE + 10)
    commit(track, "l2.txt", "l\n", "local two", BASE + 20)
    commit(seed, "r1.txt", "r\n", "remote one", BASE + 30)
    git(seed, "push", "-q", "origin", "main", env=GIT_ENV)
    git(track, "fetch", "-q", "origin")
    with open(os.path.join(track, "l1.txt"), "w") as f:
        f.write("stash me\n")
    git(track, "stash", "push", "-q", env=GIT_ENV)
    with open(os.path.join(track, "l1.txt"), "w") as f:
        f.write("edited\n")
    with open(os.path.join(track, "u1.txt"), "w") as f:
        f.write("u\n")
    with open(os.path.join(track, "u2.txt"), "w") as f:
        f.write("u\n")
    s = SizedSession(binpath, track, 80)
    line = top(s)
    check("statusline: it is the frame's top row", line.startswith("╭") and "main" in line, line)
    check("statusline: branch and upstream", "main" in line and "→ origin/main" in line, line)
    check("statusline: ahead 2, behind 1", "↑2 ↓1" in line, line)
    check("statusline: one stash", "stash 1" in line, line)
    check("statusline: counts (1 unstaged, 2 untracked)", "~1 ?2" in line, line)
    check("statusline: the repository's name", line.rstrip("─╮ ").endswith("track"), line)
    check("statusline: git agrees about ahead/behind", git(track, "rev-list", "--left-right", "--count", "HEAD...@{u}")[0] == "2\t1", "")
    # the auto-refresh
    git(track, "add", "l1.txt")
    seen = wait_for(s, lambda t: "+1 ?2" in t.split("\n")[0], 4.0)
    check("statusline: an external git add updates it without a key", seen, top(s))
    git(track, "stash", "push", "-q", "-u", env=GIT_ENV)
    seen = wait_for(s, lambda t: "stash 2" in t.split("\n")[0] and "clean" in t.split("\n")[0], 4.0)
    check("statusline: a stash from outside shows (and a clean tree says clean)", seen, top(s))
    s.quit()

    # detached
    git(track, "checkout", "-q", "--detach", "HEAD~1")
    want, _, _ = git(track, "rev-parse", "--short=7", "HEAD")
    s = SizedSession(binpath, track, 80)
    line = top(s)
    check("statusline: detached HEAD shows the short commit", "detached @ " + want in line, line)
    check("statusline: a detached HEAD has no upstream", "no upstream" not in line and "→" not in line, line)
    s.quit()
    git(track, "checkout", "-q", "main")

    # mid-merge
    mg = make_fixture(root, "merge")
    commit(mg, "f.txt", "base\n", "base", BASE)
    git(mg, "checkout", "-q", "-b", "other")
    commit(mg, "f.txt", "other side\n", "other", BASE + 10)
    git(mg, "checkout", "-q", "main")
    commit(mg, "f.txt", "main side\n", "main", BASE + 20)
    _, _, rc = git(mg, "merge", "other", env=GIT_ENV)
    check("statusline: fixture merge conflicts", rc != 0, "rc=%r" % rc)
    s = SizedSession(binpath, mg, 80)
    line = top(s)
    check("statusline: MERGING and one conflict", "MERGING" in line and "!1" in line, line)
    s.send("i")
    t = s.text()
    check("overview: shows the operation and the conflict", "Operation   MERGING" in t and "1 conflicted" in t, t)
    s.send("\x1b")
    s.quit()

    # unborn
    ub = make_fixture(root, "unborn")
    s = SizedSession(binpath, ub, 80)
    check("statusline: an unborn branch", "main (no commits yet)" in top(s), top(s))
    s.quit()

    # narrow
    s = SizedSession(binpath, track, 44)
    line = top(s)
    check("statusline narrow: the branch is kept", " main" in line, line)
    check("statusline narrow: the repository name and the stash count go first", "track" not in line and "stash" not in line, line)
    check("statusline narrow: still one line inside the border", line.startswith("╭") and line.endswith("╮") and len(line) == 44, repr(line))
    s.quit()
    s = SizedSession(binpath, track, 20)
    line = top(s)
    check("statusline very narrow: the branch alone", " main" in line and "origin" not in line, line)
    s.quit()

    # ---------------------------------------------------------- the overview
    git(track, "stash", "pop", "-q")  # leaves stashes: 1 (the -u one stays) -> check below
    s = SizedSession(binpath, track, 80)
    s.send("i")
    t = s.text()
    check("overview: the lines", "Branch      main" in t and "Upstream    origin/main  ahead 2, behind 1" in t and "Stashes" in t and "Changes" in t and "Repository" in t, t)
    s.send("\r")
    check("overview: Enter on Branch opens the branch picker", "check out a branch" in s.text() and "main" in s.text(), s.text())
    s.send("\x1b")
    s.send("i")
    s.send("j")
    s.send("\r")
    t = s.text()
    check("overview: Enter on Upstream lists the remote branches, upstream first", "remote branches" in t and "origin/main" in t, t)
    s.send("\r")
    t = s.text()
    check("overview: picking one shows its commit", "commit " in t and "remote one" in t, t)
    s.send("q")
    s.send("i")
    s.send("jj")
    s.send("\r")
    t = s.text()
    check("overview: Enter on Stashes opens the stash list", "stash@{0}" in t, t)
    s.send("\x1b")
    s.send("i")
    s.send("jjj")
    s.send("\r")
    t = s.text()
    check("overview: Enter on Changes closes it and lands on the Unstaged section", "overview" not in t and "Untracked files (2)" in t, t)
    s.send("\t")
    check("overview: ... the cursor is on that section (Tab folds Unstaged)", "\u25b8 Unstaged changes (1)" in s.text(), s.text())
    s.send("i")
    s.send("jjjj")
    s.send("\r")
    check("overview: Operation with none under way is not openable", "nothing to open for op" in s.text() and "overview" in s.text(), s.text())
    s.send("\x1b")
    check("overview: Escape closes it", "overview" not in s.text().split("\n")[3], s.text())
    rc = s.quit()
    check("overview: the client exits cleanly", rc == 0, "rc=%r" % rc)

    # help lists the keys
    s = SizedSession(binpath, track, 100, rows=60)
    s.send("?")
    t = s.text()
    check("help: the section keys are listed", "previous section header" in t and "next section header" in t and "fold every section" in t, t)
    s.send("\x1b")
    s.quit()
    return failures


if __name__ == "__main__":
    sys.exit(main())
