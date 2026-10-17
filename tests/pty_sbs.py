#!/usr/bin/env python3
"""The side-by-side diff view, driven under a real pty.

    python3 tests/pty_sbs.py <mgit-binary> <scratch-dir> [--update]

Each case builds a disposable repository, opens `mgit` on a pty of a chosen
size and checks what is on the screen (and, for staging, what git says
afterwards): the view toggle and `diff.view`, the 120-column auto rule, the
fallback to unified when the pane is narrow, a resize, hunk and line staging
from either side, the mouse wheel and a click, and the widened context. The
screen of the split view at 160 columns and of the unified view at 80 are
compared with `tests/golden/sbs/pty_*.txt` (`--update` rewrites them).

ASCII only in the fixtures: the screen model of `pty_e2e` counts one column
per code point.
"""
import fcntl
import os
import pty
import re
import shutil
import struct
import subprocess
import sys
import termios
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pty_e2e  # noqa: E402
from pty_e2e import CLIENT_ENV, GIT_ENV, Screen, git, make_fixture  # noqa: E402

GOLDEN = os.path.join(HERE, "golden", "sbs")
failures = 0
update = "--update" in sys.argv


def check(name, condition, detail=""):
    global failures
    if condition:
        print("ok   " + name, flush=True)
    else:
        failures += 1
        print("FAIL " + name + ": " + detail, flush=True)


class Sess(pty_e2e.Session):
    """`pty_e2e.Session` with a window size, a resize and the mouse."""

    def __init__(self, binpath, fixture, rows, cols, env=None):
        self.screen = Screen(rows, cols)
        self.master, slave = pty.openpty()
        self.set_size(slave, rows, cols)
        self.proc = subprocess.Popen(
            [binpath, fixture], stdin=slave, stdout=slave, stderr=slave, cwd=fixture,
            env=env if env is not None else CLIENT_ENV,
        )
        os.close(slave)
        time.sleep(0.4)
        self.drain()

    @staticmethod
    def set_size(fd, rows, cols):
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def resize(self, rows, cols):
        self.set_size(self.master, rows, cols)
        self.screen = Screen(rows, cols)
        time.sleep(0.5)  # the loop notices a new size on its next tick
        self.send("")
        self.drain(0.6)

    def wheel(self, down, x, y, times=1):
        button = 65 if down else 64
        for _ in range(times):
            self.send("\x1b[<%d;%d;%dM" % (button, x + 1, y + 1))

    def click(self, x, y):
        self.send("\x1b[<0;%d;%dM" % (x + 1, y + 1))
        self.send("\x1b[<0;%d;%dm" % (x + 1, y + 1))

    def where(self, needle):
        """(column, row) of the first occurrence of `needle` on the screen."""
        for row, text in enumerate(self.screen.text().split("\n")):
            col = text.find(needle)
            if col >= 0:
                return col, row
        return None


BASE = "".join("line %d\n" % i for i in range(1, 31))


def changed():
    new = ["line %d" % i for i in range(1, 31)]
    new[2] = "line 3 changed"
    del new[14]
    new[27] = "line 28 changed now"
    return "\n".join(new) + "\n"


def make_repo(root, name, config=None):
    fx = make_fixture(root, name)
    with open(os.path.join(fx, "src.txt"), "w") as f:
        f.write(BASE)
    git(fx, "add", "-A", env=GIT_ENV)
    git(fx, "commit", "-q", "-m", "base", env=GIT_ENV)
    with open(os.path.join(fx, "src.txt"), "w") as f:
        f.write(changed())
    if config:
        git(fx, "config", "diff.view", config)
    return fx


def open_diff(session):
    session.send("j")
    session.send("j")
    session.send("d")


def block(text):
    """The inside of the diff view's frame: the rows between its title and its
    bottom border, with its edges taken off."""
    rows = text.split("\n")
    out = []
    inside = False
    for row in rows:
        if "diff: " in row and "┌" in row:
            inside = True
            continue
        if inside and "└" in row:
            break
        if inside:
            out.append(row[1:-1].rstrip())
    return "\n".join(out) + "\n"


def golden(name, got):
    path = os.path.join(GOLDEN, name)
    if update:
        os.makedirs(GOLDEN, exist_ok=True)
        with open(path, "w") as f:
            f.write(got)
        check("golden " + name + " (rewritten)", True)
        return
    try:
        with open(path) as f:
            want = f.read()
    except OSError:
        check("golden " + name, False, "missing " + path)
        return
    check("golden " + name, got == want, "screen differs from " + path + ":\n" + got)


def same_row(session, *needles):
    for text in session.screen.text().split("\n"):
        if all(n in text for n in needles):
            return True
    return False


def index_lines(fx):
    out, _, _ = git(fx, "show", ":src.txt")
    return out.split("\n")


def main():
    if len(sys.argv) < 3:
        print("usage: pty_sbs.py <mgit-binary> <scratch-dir> [--update]", file=sys.stderr)
        return 2
    binpath = os.path.abspath(sys.argv[1])
    root = os.path.abspath(sys.argv[2])
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(root)

    # --- wide: split by default, toggle, remembered --------------------------
    fx = make_repo(root, "wide")
    s = Sess(binpath, fx, 30, 160)
    open_diff(s)
    text = s.text()
    check("auto: 160 columns draws side by side", "[side by side]" in text, text)
    check("split: a removal and its replacement share a row", same_row(s, "-line 3", "+line 3 changed"), text)
    check("split: the ruler names the old and the new side", same_row(s, "src.txt  (index)", "src.txt  (working tree)"), text)
    check("split: the gutter marks a change and a removal", same_row(s, "~") and same_row(s, "-line 15"), text)
    check("split: unchanged lines are shown on both sides", same_row(s, " 1  line 1", " 1  line 1"), text)
    check("split: hidden lines are counted", "unchanged lines" in text, text)
    golden("pty_split_160.txt", block(text))
    s.send("D")
    text = s.text()
    check("D: back to the unified view", "[side by side]" not in text and same_row(s, "unified diff"), text)
    view, _, _ = git(fx, "config", "diff.view")
    check("D: the choice is kept in diff.view", view == "unified", repr(view))
    s.send("D")
    check("D again: side by side", "[side by side]" in s.text(), s.text())
    view, _, _ = git(fx, "config", "diff.view")
    check("D again: diff.view is split", view == "split", repr(view))
    # a resize keeps the view and re-lays it out; a narrow pane falls back
    s.resize(30, 100)
    text = s.text()
    check("resize to 100 columns: still side by side, both sides fit", "[side by side]" in text and same_row(s, "-line 3", "+line 3 changed"), text)
    s.resize(30, 50)
    text = s.text()
    check("resize to 50 columns: falls back to the unified view", "[side by side]" not in text and "line 3 changed" in text, text)
    s.resize(30, 160)
    check("resize back to 160 columns: side by side again", "[side by side]" in s.text(), s.text())
    s.quit()

    # --- narrow: inline by default, split on request ---------------------------
    fx = make_repo(root, "narrow")
    s = Sess(binpath, fx, 30, 80)
    open_diff(s)
    text = s.text()
    check("auto: 80 columns stays unified", "[side by side]" not in text and "+line 3 changed" in text, text)
    golden("pty_unified_80.txt", block(text))
    s.send("D")
    text = s.text()
    check("D at 80 columns: side by side fits", "[side by side]" in text and same_row(s, "-line 3", "+line 3 changed"), text)
    s.quit()
    fx = make_repo(root, "tiny")
    s = Sess(binpath, fx, 30, 50)
    open_diff(s)
    s.send("D")
    text = s.text()
    check("D at 50 columns: says why it stays unified", "needs a pane of 60 columns" in text and "[side by side]" not in text, text)
    s.quit()
    fx = make_repo(root, "pinned", config="unified")
    s = Sess(binpath, fx, 30, 160)
    open_diff(s)
    check("diff.view=unified: not side by side even at 160", "[side by side]" not in s.text(), s.text())
    s.quit()
    fx = make_repo(root, "pinned2", config="split")
    s = Sess(binpath, fx, 30, 100)
    open_diff(s)
    check("diff.view=split: side by side at 100 columns", "[side by side]" in s.text(), s.text())
    s.quit()

    # --- staging from the split view ------------------------------------------
    fx = make_repo(root, "hunk")
    s = Sess(binpath, fx, 30, 160)
    open_diff(s)
    s.send("]")
    s.send("s")
    s.quit()
    stat, _, _ = git(fx, "diff", "--cached", "--numstat")
    want = BASE.rstrip("\n").split("\n")
    del want[14]
    check("split: ] then s stages that hunk only (the removal of line 15)", stat == "0\t1\tsrc.txt" and index_lines(fx) == want, stat)
    fsck, _, _ = git(fx, "fsck", "--full")
    check("split: fsck is clean after hunk staging", fsck == "", fsck)

    fx = make_repo(root, "right")
    s = Sess(binpath, fx, 30, 160)
    open_diff(s)
    s.send("jjj")
    s.send(" ")
    s.quit()
    got = index_lines(fx)
    want = BASE.rstrip("\n").split("\n")
    want.insert(3, "line 3 changed")
    check("split: space on the right side stages the addition only", got == want, "\n".join(got[:6]))
    check("split: the working file is untouched by staging", open(os.path.join(fx, "src.txt")).read() == changed(), "")

    fx = make_repo(root, "left")
    s = Sess(binpath, fx, 30, 160)
    open_diff(s)
    s.send("jjj")
    s.send("h")
    s.send(" ")
    s.quit()
    got = index_lines(fx)
    want = BASE.rstrip("\n").split("\n")
    del want[2]
    check("split: h then space stages the removal only", got == want, "\n".join(got[:6]))

    fx = make_repo(root, "visual")
    s = Sess(binpath, fx, 30, 160)
    open_diff(s)
    s.send("jj")
    s.send("v")
    s.send("jj")
    text = s.text()
    check("split: v starts a visual range", "[visual]" in text, text)
    s.send(" ")
    s.quit()
    got = index_lines(fx)
    want = BASE.rstrip("\n").split("\n")
    want[2] = "line 3 changed"
    check("split: a visual range stages the removal and the addition together", got == want, "\n".join(got[:6]))

    fx = make_repo(root, "discard")
    s = Sess(binpath, fx, 30, 160)
    open_diff(s)
    s.send("jjj")
    s.send("x")
    check("split: x asks before discarding", "discard 1 line(s)" in s.text(), s.text())
    s.send("y")
    s.quit()
    work = open(os.path.join(fx, "src.txt")).read()
    lines = work.rstrip("\n").split("\n")
    check("split: x y discards the line under the cursor from the working tree", "line 3 changed" not in lines and "line 28 changed now" in lines and len(lines) == 28, work[:60])

    fx = make_repo(root, "unstage")
    git(fx, "add", "-A", env=GIT_ENV)
    s = Sess(binpath, fx, 30, 160)
    for key in "jjjd":
        s.send(key)
    text = s.text()
    check("split: the staged diff is side by side too", "[side by side]" in text and same_row(s, "src.txt  (HEAD)", "src.txt  (index)"), text)
    s.send("]")
    s.send("u")
    s.quit()
    stat, _, _ = git(fx, "diff", "--cached", "--numstat")
    check("split: ] then u unstages that hunk only", stat == "2\t2\tsrc.txt", stat)

    # --- the commit's files, the commit view and the stash preview ------------------
    fx = make_repo(root, "commit")
    git(fx, "add", "-A", env=GIT_ENV)
    git(fx, "commit", "-q", "-m", "second", env=GIT_ENV)
    s = Sess(binpath, fx, 30, 160)
    for key in "3j":  # History, the first commit row
        s.send(key)
    s.send("\r")
    for key in "jjjjj":
        s.send(key)
    s.send("d")
    text = s.text()
    check("split: a commit's file diff names both revisions", "[side by side]" in text and re.search(r"src\.txt  \(\w{7}\^\) +src\.txt  \(\w{7}\)", text) is not None, text)
    check("split: ... and pairs its removed and added lines", same_row(s, "-line 3", "+line 3 changed"), text)
    s.send("q")
    s.send("H")
    s.send("j")
    s.send("\r")
    text = s.text()
    check("split: the commit view (history, Enter) is side by side", "commit " in text and re.search(r"src\.txt  \(\w{7}\^\) +src\.txt  \(\w{7}\)", text) is not None, text)
    s.send("D")
    text = s.text()
    check("D in the commit view: back to the unified text", "--- src.txt" in text, text)
    s.quit()
    fx = make_repo(root, "stash")
    git(fx, "stash", "push", "-q", env=GIT_ENV)
    s = Sess(binpath, fx, 30, 160)
    s.send("5")
    s.send("z")
    s.send("l")
    text = s.text()
    check("split: the stash preview is side by side", "src.txt (" in text and same_row(s, "-line 3", "+line 3 changed"), text)
    s.send("D")
    text = s.text()
    check("D in the stash list: back to the unified text", "diff --git a/src.txt" in text, text)
    s.quit()

    # --- folding a hunk, as in the unified view --------------------------------------
    fx = make_repo(root, "fold")
    s = Sess(binpath, fx, 30, 160)
    open_diff(s)
    s.send("f")
    text = s.text()
    check("f folds the hunk under the cursor, saying how many lines it hides", "@@ -1,6 +1,6 @@" in text and "(7 lines)" in text and not same_row(s, " 1  line 1") and same_row(s, "12  line 12"), text)
    s.send("f")
    check("f again unfolds it", same_row(s, " 1  line 1"), s.text())
    s.send("-")
    text = s.text()
    check("- folds every hunk", "@@ -26,5 +25,5 @@" in text and not same_row(s, "26  line 26") and not same_row(s, "12  line 12"), text)
    s.send("+")
    check("+ unfolds every hunk", same_row(s, "26  line 26"), s.text())
    s.quit()

    # --- long lines: wrapped per side, or scrolled together ------------------------
    fx = make_fixture(root, "long")
    digits = "0123456789" * 30
    with open(os.path.join(fx, "long.txt"), "w") as f:
        f.write("top\n" + digits + "\nbottom\n")
    git(fx, "add", "-A", env=GIT_ENV)
    git(fx, "commit", "-q", "-m", "base", env=GIT_ENV)
    with open(os.path.join(fx, "long.txt"), "w") as f:
        f.write("top\n" + digits + "X\nbottom\n")
    s = Sess(binpath, fx, 30, 160)
    open_diff(s)
    text = s.text()
    first = digits[:60]
    check("long line: wrapped on both sides, the rows stay aligned", same_row(s, "-" + first, "+" + first) and "[side by side]" in text, text)
    check("long line: the continuation has no number or marker", same_row(s, digits[80:100]) and "X" in text, text)
    s.send("w")
    text = s.text()
    check("w: one row per line, both sides cut at their edge", "scroll" in text and same_row(s, "-" + first, "+" + first) and "X" not in text.split("bottom")[0].split("diff:")[-1], text)
    s.send(">")
    s.send(">")
    text = s.text()
    check("> scrolls both sides together", same_row(s, "-" + digits[16:60], "+" + digits[16:60]) and not same_row(s, "-" + first), text)
    s.send("w")
    check("w again: wrapped again", "wrap" in s.text(), s.text())
    s.quit()

    # --- widened context: lines that cannot be staged ---------------------------
    fx = make_repo(root, "widen")
    s = Sess(binpath, fx, 30, 160)
    open_diff(s)
    s.send("e")
    text = s.text()
    check("e: more unchanged lines around the hunks", "context: 10 lines" in text and "line 9" in text, text)
    s.send("j" * 9)
    s.send(" ")
    text = s.text()
    check("a line shown only by widening says it cannot be staged", "only context from widening" in text, text)
    stat, _, _ = git(fx, "diff", "--cached", "--numstat")
    check("... and nothing was staged", stat == "", stat)
    s.send("E")
    check("E: back to 3 lines of context", "3 lines of context" in s.text(), s.text())
    s.quit()

    # --- the mouse -------------------------------------------------------------
    fx = make_repo(root, "mouse")
    s = Sess(binpath, fx, 30, 160)
    open_diff(s)
    s.send("e")
    s.send("e")
    s.send("e")
    s.send("e")
    check("whole file: the ruler is at the top", "src.txt  (index)" in s.text(), s.text())
    s.wheel(True, 80, 10, times=3)
    text = s.text()
    check("wheel down scrolls both sides together", "src.txt  (index)" not in text and same_row(s, "line 30", "line 30"), text)
    s.wheel(False, 80, 10, times=6)
    check("wheel up scrolls back", "src.txt  (index)" in s.text(), s.text())
    s.quit()
    fx = make_repo(root, "click")
    s = Sess(binpath, fx, 30, 160)
    open_diff(s)
    where = s.where("+line 28 changed now")
    check("click: the third hunk is on screen", where is not None, s.text())
    if where:
        s.click(where[0] + 3, where[1])
        s.send("s")
        s.quit()
        stat, _, _ = git(fx, "diff", "--cached", "--numstat")
        check("click on a row then s stages that row's hunk", stat == "1\t1\tsrc.txt" and "line 28 changed now" in git(fx, "show", ":src.txt")[0], stat)
    else:
        s.quit()

    return failures


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
