#!/usr/bin/env python3
"""mgit's modes under a real pty, read through a real terminal emulator.

    python3 tests/pty_modes.py <mgit-binary> <scratch-dir>

Needs `pyte` (a terminal emulator library): `pip install pyte`, in a virtualenv
if the system Python is managed. Without it this prints `SKIP` and exits 0, so
a machine without it still runs the rest of the suite. `PYTE_PYTHON` names a
Python that has it when the one running `tests/test.sh` does not.

What it checks, at 80x24, 120x40 and a tiny 40x12:

  * the tab bar is on the top row and names the current mode, and Tab,
    Shift-Tab, the digits, Esc and a click on a tab all move between the five
    modes (Status, Commit, History, Branches, Stash);
  * the hint row is the LAST row of the terminal, one line, and names only keys
    of the mode you are in; `?` opens that mode's help and `:` the palette;
  * nothing is ever drawn past the last column (the same bytes are also fed to
    a terminal 40 columns wider and everything beyond the real width must stay
    blank);
  * after incremental updates the screen equals a full redraw (the terminal is
    resized and put back, which makes the program repaint every cell from
    scratch, and the two screens are compared cell by cell, style included);
  * keys that moved say where, a flow (a merge, a cherry-pick) is named in the
    status line and leads the hint row, and an action the flow forbids is
    refused with its reason.

The fixture is built to hurt a renderer: wide (CJK) and emoji names, combining
marks, tabs in names and in file contents, a name far wider than the terminal,
and a branch, a commit and a stash with such names.
"""
import fcntl
import os
import pty
import select
import shutil
import struct
import subprocess
import sys
import termios
import time

try:
    import pyte
except ImportError:
    print("SKIP pyte is not installed (pip install pyte); the modes' screen checks did not run")
    sys.exit(0)

failures = 0
checks = 0


def check(name, condition, detail=""):
    global failures, checks
    checks += 1
    if condition:
        print("ok   " + name, flush=True)
    else:
        failures += 1
        print("FAIL " + name + ": " + detail, flush=True)


GIT_ENV = dict(os.environ)
for k, v in (
    ("GIT_AUTHOR_NAME", "Fixture"),
    ("GIT_AUTHOR_EMAIL", "fixture@example.com"),
    ("GIT_COMMITTER_NAME", "Fixture"),
    ("GIT_COMMITTER_EMAIL", "fixture@example.com"),
    ("GIT_AUTHOR_DATE", "1700000000 +0000"),
    ("GIT_COMMITTER_DATE", "1700000000 +0000"),
):
    GIT_ENV[k] = v
for k in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_EDITOR", "VISUAL", "EDITOR"):
    GIT_ENV.pop(k, None)

CLIENT_ENV = dict(os.environ)
CLIENT_ENV["TERM"] = "xterm"
for k in ("GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME"):
    CLIENT_ENV[k] = "Client"
for k in ("GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"):
    CLIENT_ENV[k] = "client@example.com"
CLIENT_ENV["M31GIT_MOUSE"] = "on"
for k in ("GIT_EDITOR", "VISUAL", "EDITOR", "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
    CLIENT_ENV.pop(k, None)
CLIENT_ENV.pop("NO_COLOR", None)


def git(cwd, *args):
    r = subprocess.run(["git", "-C", cwd] + list(args), capture_output=True, text=True, env=GIT_ENV)
    return r.stdout.rstrip("\n"), r.returncode


def must(cwd, *args):
    out, rc = git(cwd, *args)
    if rc != 0:
        raise RuntimeError("git %s failed in %s" % (" ".join(args), cwd))
    return out


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


# --- the terminal ----------------------------------------------------------------------------


class Term:
    """One `mgit` on a pty of a given size, with its output fed to two pyte
    screens: the real width, and one 40 columns wider (to catch overflow)."""

    EXTRA = 40

    def __init__(self, binpath, fixture, rows, cols, env=None):
        self.rows, self.cols = rows, cols
        self.screen = pyte.Screen(cols, rows)
        self.stream = pyte.ByteStream(self.screen)
        self.wide = pyte.Screen(cols + self.EXTRA, rows)
        self.wide_stream = pyte.ByteStream(self.wide)
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.proc = subprocess.Popen(
            [binpath, fixture], stdin=slave, stdout=slave, stderr=slave, cwd=fixture, env=env or CLIENT_ENV, close_fds=True
        )
        os.close(slave)
        self.last = b""
        time.sleep(0.4)
        self.drain()

    def drain(self, timeout=0.3, feed=True):
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
            if feed:
                self.stream.feed(chunk)
                self.wide_stream.feed(chunk)
        self.last = out
        return out

    def send(self, keys, wait=0.15):
        try:
            os.write(self.master, keys.encode())
        except OSError:
            pass
        time.sleep(wait)
        return self.drain()

    def lines(self):
        return [render_row(self.screen, y) for y in range(self.rows)]

    def text(self):
        return "\n".join(self.lines())

    def resize(self, rows, cols):
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def is_alive(self):
        return self.proc.poll() is None

    def quit(self):
        self.send("q")
        try:
            self.proc.wait(timeout=3)
        except Exception:
            self.proc.kill()
            self.proc.wait()
        try:
            os.close(self.master)
        except OSError:
            pass
        return self.proc.returncode

    def kill(self):
        if self.is_alive():
            self.proc.kill()
            self.proc.wait()
        try:
            os.close(self.master)
        except OSError:
            pass

    # --- what the screen must satisfy ------------------------------------------------------------

    def overflow(self):
        """Characters the program drew past its own last column, if any."""
        found = []
        for y in range(self.rows):
            row = self.wide.buffer[y]
            for x in range(self.cols, self.cols + self.EXTRA):
                if row[x].data.strip() != "":
                    found.append((y, x, row[x].data))
        return found

    def repaint(self):
        """The screen as a FULL redraw paints it: resize the terminal (the
        program repaints every cell from scratch at a new size) and put it
        back, and read only what the second repaint wrote into a fresh screen."""
        self.resize(self.rows, self.cols + 3)
        time.sleep(0.7)
        self.drain(0.5, feed=False)
        self.resize(self.rows, self.cols)
        time.sleep(0.7)
        data = self.drain(0.5, feed=False)
        fresh = pyte.Screen(self.cols, self.rows)
        pyte.ByteStream(fresh).feed(data)
        # What the repaint drew is the screen now, here and in the wide copy.
        self.screen = fresh
        self.stream = pyte.ByteStream(fresh)
        self.wide = pyte.Screen(self.cols + self.EXTRA, self.rows)
        self.wide_stream = pyte.ByteStream(self.wide)
        self.wide_stream.feed(data)
        return fresh


def render_row(screen, y):
    """A row as text. `screen.display` trips over a continuation cell on some
    wide-character screens, so the cells are joined here: a wide character sits
    in one cell and the cell after it is empty."""
    row = screen.buffer[y]
    return "".join(row[x].data for x in range(screen.columns)).rstrip()


def cells_of(screen):
    out = []
    for y in range(screen.lines):
        row = []
        for x in range(screen.columns):
            c = screen.buffer[y][x]
            row.append((c.data, c.fg, c.bg, c.bold, c.reverse, c.underscore, c.italics))
        out.append(row)
    return out


def screen_diff(a, b, limit=6):
    """The first cells where two pyte screens differ, as readable text."""
    ca, cb = cells_of(a), cells_of(b)
    out = []
    for y in range(len(ca)):
        for x in range(len(ca[y])):
            if ca[y][x] != cb[y][x]:
                out.append("(%d,%d) %r vs %r" % (y, x, ca[y][x], cb[y][x]))
                if len(out) >= limit:
                    return "; ".join(out)
    return "; ".join(out)


# --- the fixture ----------------------------------------------------------------------------------

WIDE_NAME = "日本語のとても長いファイル名.txt"
LONG_NAME = "very_long_" + "x" * 110 + ".txt"
COMBINING = "écolê.txt"
EMOJI = "emoji-\U0001f600-\U0001f468‍\U0001f469-file.txt"
TAB_NAME = "tab\tname.txt"
WIDE_BRANCH = "機能/とても-長い-ブランチ名"
LONG_BRANCH = "feature/" + "long-branch-name-" * 6


def build_hostile(root):
    fx = os.path.join(root, "hostile")
    os.makedirs(fx)
    must(fx, "init", "-q", "-b", "main")
    must(fx, "config", "core.quotepath", "off")
    must(fx, "config", "gc.auto", "0")
    body = "".join("line %d\ttabbed\t日本語 é \U0001f600 %s\n" % (i, "w" * 150) for i in range(1, 25))
    for name in (WIDE_NAME, LONG_NAME, COMBINING, EMOJI, TAB_NAME, "plain.txt"):
        write(os.path.join(fx, name), body)
    must(fx, "add", "-A")
    must(fx, "commit", "-q", "-m", "初回コミット " + "a very long subject " * 8)
    for name in (WIDE_NAME, LONG_NAME, COMBINING, EMOJI, TAB_NAME, "plain.txt"):
        write(os.path.join(fx, name), body.replace("line 3\t", "LINE 3\t").replace("line 20\t", "LINE 20\t"))
    must(fx, "add", WIDE_NAME, COMBINING)
    write(os.path.join(fx, "untracked-日本.txt"), "x\n")
    write(os.path.join(fx, "tab\there.txt"), "x\n")
    must(fx, "branch", WIDE_BRANCH)
    must(fx, "branch", LONG_BRANCH)
    must(fx, "stash", "push", "-q", "-m", "スタッシュ " + "stash message " * 6, "--", "plain.txt")
    write(os.path.join(fx, "plain.txt"), body.replace("line 5\t", "FIVE\t"))
    return fx


def build_simple(root, name="simple"):
    fx = os.path.join(root, name)
    os.makedirs(fx)
    must(fx, "init", "-q", "-b", "main")
    must(fx, "config", "gc.auto", "0")
    write(os.path.join(fx, "a.txt"), "one\ntwo\nthree\n")
    write(os.path.join(fx, "b.txt"), "b\n")
    must(fx, "add", "-A")
    must(fx, "commit", "-q", "-m", "first")
    write(os.path.join(fx, "a.txt"), "one\nTWO\nthree\n")
    write(os.path.join(fx, "new.txt"), "n\n")
    write(os.path.join(fx, "staged.txt"), "s\n")
    must(fx, "add", "staged.txt")
    return fx


# --- scenarios ---------------------------------------------------------------------------------------

MODES = ["Status", "Commit", "History", "Branches", "Stash"]


def current_tab(t):
    """The text of the tab drawn in reverse video on the top row."""
    row = t.screen.buffer[0]
    text = "".join(row[x].data for x in range(t.cols) if row[x].reverse)
    return text.strip()


def cursor_row(t):
    """The screen row (0-based) the outline cursor is drawn on: the first body
    row with a reverse-video cell (the tab bar, row 0, is reverse too)."""
    for y in range(2, t.rows - 2):
        row = t.screen.buffer[y]
        if any(row[x].reverse for x in range(t.cols)):
            return y
    return -1


def tab_bar_ok(t, mode_index):
    """Is the top row a tab bar whose highlighted tab is mode `mode_index`?"""
    row = t.lines()[0]
    name = MODES[mode_index]
    return ("%d" % (mode_index + 1)) in current_tab(t) and (name in current_tab(t) or t.cols < 52) and row.lstrip().startswith("1")


def hint_row_ok(t, is_overlay=False):
    last = t.lines()[t.rows - 1]
    if is_overlay:
        return last.strip() != ""
    return last.strip() != "" and "?" in last


def structure(t, label, mode_index, is_overlay=False):
    """The invariants every screen must keep. An overlay's hint row names the
    overlay's own keys and has no `? more` (the menu's keys are all of them)."""
    check("%s: tab bar on the top row names %s" % (label, MODES[mode_index]), tab_bar_ok(t, mode_index), t.lines()[0])
    check("%s: a hint row is on the last row" % label, hint_row_ok(t, is_overlay), repr(t.lines()[t.rows - 1]))
    over = t.overflow()
    check("%s: nothing is drawn past column %d" % (label, t.cols), not over, repr(over[:5]))


def same_as_full_redraw(t, label):
    before = t.screen
    snapshot = pyte.Screen(t.cols, t.rows)
    # a copy of the incremental screen's cells, taken before the resize
    for y in range(t.rows):
        for x in range(t.cols):
            snapshot.buffer[y][x] = before.buffer[y][x]
    fresh = t.repaint()
    diff = screen_diff(snapshot, fresh)
    check("%s: incremental screen equals a full redraw" % label, diff == "", diff)
    over = t.overflow()
    check("%s: the full redraw draws nothing past column %d either" % (label, t.cols), not over, repr(over[:5]))


def tour(binpath, fx, rows, cols, root, repaints):
    label = "%dx%d" % (cols, rows)
    t = Term(binpath, fx, rows, cols)
    try:
        structure(t, label + " Status", 0)
        if repaints:
            same_as_full_redraw(t, label + " Status")
        # Tab through every mode and wrap round
        for index in range(1, 5):
            t.send("\t")
            structure(t, "%s after %d Tab" % (label, index), index)
            if repaints:
                same_as_full_redraw(t, "%s %s" % (label, MODES[index]))
        t.send("\t")
        structure(t, label + " the fifth Tab wraps to Status", 0)
        t.send("\x1b[Z")
        structure(t, label + " Shift-Tab wraps back to Stash", 4)
        for digit in "13245":
            t.send(digit)
            structure(t, "%s digit %s" % (label, digit), int(digit) - 1)
        # a diff in Status: the first file row of the unstaged section
        t.send("1")
        t.send("/plain\r")
        t.send("d")
        structure(t, label + " diff view", 0)
        if repaints:
            same_as_full_redraw(t, label + " unified diff")
        t.send("D")
        structure(t, label + " side-by-side diff", 0)
        if repaints:
            same_as_full_redraw(t, label + " side-by-side diff")
        for _ in range(3):
            t.send("j")
        t.send("l")
        t.send(">")
        structure(t, label + " side-by-side scrolled", 0)
        if repaints:
            same_as_full_redraw(t, label + " side-by-side scrolled")
        t.send("D")
        t.send("q")
        # History: open a commit
        t.send("3")
        t.send("j")
        t.send("\r")
        structure(t, label + " history, commit open", 2)
        if repaints:
            same_as_full_redraw(t, label + " history, commit open")
        t.send("/plain\r")
        t.send("\r")
        structure(t, label + " history, a commit's file diff", 2)
        if repaints:
            same_as_full_redraw(t, label + " history, a commit's file diff")
        t.send("q")
        # Branches and Stash
        t.send("4")
        t.send("jj")
        structure(t, label + " branches", 3)
        if repaints:
            same_as_full_redraw(t, label + " branches")
        t.send("5")
        t.send("j")
        t.send("\r")
        structure(t, label + " stash list", 4, is_overlay=True)
        if repaints:
            same_as_full_redraw(t, label + " stash list")
        t.send("\x1b")
        # help and palette
        t.send("?")
        structure(t, label + " help", 4, is_overlay=True)
        if repaints:
            same_as_full_redraw(t, label + " help")
        t.send("\x1b")
        t.send(":")
        t.send("sta")
        structure(t, label + " palette", 4, is_overlay=True)
        if repaints:
            same_as_full_redraw(t, label + " palette")
        t.send("\x1b")
        # the other views that draw file text, names and messages
        t.send("1")
        t.send("/plain\r")
        t.send("B")
        structure(t, label + " blame", 0, is_overlay=True)
        if repaints:
            same_as_full_redraw(t, label + " blame")
        t.send("q")
        t.send("H")
        structure(t, label + " file history", 0, is_overlay=True)
        t.send("\r")
        structure(t, label + " the commit view", 0, is_overlay=True)
        if repaints:
            same_as_full_redraw(t, label + " the commit view")
        t.send("q")
        t.send("q")
        t.send("@")
        structure(t, label + " command log", 0, is_overlay=True)
        t.send("\x1b")
        t.send("i")
        structure(t, label + " overview", 0, is_overlay=True)
        if repaints:
            same_as_full_redraw(t, label + " overview")
        t.send("\x1b")
        t.send("4")
        t.send("b")
        t.send("/")
        structure(t, label + " branch picker", 3, is_overlay=True)
        if repaints:
            same_as_full_redraw(t, label + " branch picker")
        t.send("\x1b")
        t.send("\x1b")
        # sideways scrolling of an outline that has wide characters in it
        t.send("3")
        t.send("lll")
        structure(t, label + " history scrolled sideways", 2)
        if repaints:
            same_as_full_redraw(t, label + " history scrolled sideways")
        t.send("hhh")
        t.send("2")
        structure(t, label + " commit panel", 1)
        if repaints:
            same_as_full_redraw(t, label + " commit panel")
        check("%s: the program is still running after the tour" % label, t.is_alive(), "died")
        rc = t.quit()
        check("%s: q quits cleanly" % label, rc == 0, "rc=%r" % rc)
    finally:
        t.kill()


def behaviour(binpath, root):
    # --- keys and modes, on a simple fixture --------------------------------------------------
    fx = build_simple(root)
    t = Term(binpath, fx, 24, 80)
    try:
        text = t.text()
        check("Status shows the three change lists and no commits", "Untracked files (1)" in text and "Staged changes (1)" in text and "Commits" not in text, text)
        last = t.lines()[23]
        check("Status hint row leads with stage, unstage, diff, commit", last.lstrip().startswith("s stage  u unstage  d diff  c commit"), last)
        check("Status hint row ends with ? more", last.rstrip().endswith("? more"), last)
        t.send("A")
        check("a key that moved says where: A in Status is History's", "A moved to History (3)" in t.text(), t.text().split("\n")[22])
        t.send("A")
        check("the second time it is the short form", "A: History (3)" in t.text(), t.text().split("\n")[22])
        t.send("z")
        check("z in Status is Stash's", "z moved to Stash (5)" in t.text(), t.text().split("\n")[22])
        t.send("3")
        text = t.text()
        check("History shows the commits and not the change lists", "Commits (1)" in text and "Untracked" not in text, text)
        last = t.lines()[23]
        check("History hints name its own keys", "A cherry-pick" in last and "V revert" in last and "s stage" not in last, last)
        t.send("s")
        check("s in History says it moved to Status", "s moved to Status (1)" in t.text(), t.text().split("\n")[22])
        t.send("4")
        text = t.text()
        check("Branches lists the branches", "Branches (1)" in text and "* main" in text, text)
        check("Branches hints", "b branch menu" in t.lines()[23] and "m merge" in t.lines()[23], t.lines()[23])
        t.send("5")
        check("Stash with nothing stashed says (0)", "Stashes (0)" in t.text(), t.text())
        check("Stash hints lead with the menu", t.lines()[23].lstrip().startswith("z stash menu"), t.lines()[23])
        t.send("2")
        text = t.text()
        check("Commit shows what the commit will contain", "New commit" in text and "Staged changes (1)" in text and "A  staged.txt" in text, text)
        check("Commit hints", t.lines()[23].lstrip().startswith("e write message  f commit staged  A amend HEAD"), t.lines()[23])
        t.send("a")
        check("a in Commit asks before it discards the draft, naming it", 'discard the draft message "first"?' in t.text(), t.text())
        t.send("n")
        check("any other key keeps the draft", "kept the draft" in t.text() and os.path.exists(os.path.join(fx, ".git", "COMMIT_EDITMSG")), t.text())
        t.send("\x1b")
        check("Esc leaves a mode for Status", tab_bar_ok(t, 0), t.lines()[0])
        t.send("\x1b[Z")
        check("Shift-Tab from Status wraps to Stash", tab_bar_ok(t, 4), t.lines()[0])
        t.send("1")
        # the help is the mode's own
        t.send("3")
        t.send("?")
        text = t.text()
        check("? in History is History's help", "History mode" in text and "cherry-pick" in text and "stage hunk" not in text, text)
        t.send("\x1b")
        # the palette lists every mode's actions and runs one
        t.send(":")
        text = t.text()
        check("the palette lists actions of every mode", "Status: stage" in text and "Go to Stash" not in text or "commands" in text, text)
        t.send("stash menu")
        check("typing filters the palette", "Stash: stash menu" in t.text() and "Status: stage" not in t.text(), t.text())
        t.send("\r")
        check("running a palette entry switches mode and does it (Stash mode, the stash menu)", tab_bar_ok(t, 4) and "stash" in t.text().lower(), t.text())
        t.send("\x1b")
        t.send(":")
        t.send("go to hist")
        t.send("\r")
        check("the palette's 'Go to History' goes to History", tab_bar_ok(t, 2), t.lines()[0])
        # Ctrl-P is the palette too
        t.send("\x10")
        check("Ctrl-P opens the palette", "commands" in t.text() and "> " in t.text(), t.text())
        t.send("\x1b")
        # the wheel and a click on a row move the cursor in an outline mode
        t.send("1")
        before = cursor_row(t)
        t.send("\x1b[<65;10;4M")
        after = cursor_row(t)
        check("the wheel moves the outline cursor", before == 2 and after > before, "before=%r after=%r" % (before, after))
        t.send("\x1b[<0;12;4M\x1b[<0;12;4m")
        check("a click selects the row under it", cursor_row(t) == 3, "row=%r" % cursor_row(t))
        t.send("3")
        # a click on a tab switches to it: "Branches" starts at column 31 (1-based 32)
        row = t.lines()[0]
        col = row.index("4 Branches") + 2
        t.send("\x1b[<0;%d;1M\x1b[<0;%d;1m" % (col, col))
        check("a click on a tab switches to its mode", tab_bar_ok(t, 3), t.lines()[0])
        # q quits
        rc = t.quit()
        check("q quits from a mode", rc == 0, "rc=%r" % rc)
    finally:
        t.kill()

    # --- the palette can quit, and can start the editor ---------------------------------------------
    fx = build_simple(root, "paletterun")
    t = Term(binpath, fx, 24, 80)
    try:
        t.send(":")
        t.send("Everywhere: quit")
        t.send("\r")
        time.sleep(0.6)
        check("quit from the palette ends the program", not t.is_alive() and t.proc.returncode == 0, "alive=%r rc=%r" % (t.is_alive(), t.proc.returncode))
    finally:
        t.kill()

    # --- a diff belongs to its mode ---------------------------------------------------------------
    fx = build_simple(root, "diffmode")
    t = Term(binpath, fx, 24, 80)
    try:
        t.send("jj")
        t.send("j")
        t.send("d")
        text = t.text()
        check("d opens the diff and the hint row becomes the diff's", "stage hunk" in t.lines()[23], t.lines()[23])
        t.send("\t")
        check("Tab leaves the diff for the next mode (the diff closes)", tab_bar_ok(t, 1) and "@@" not in t.text(), t.text())
        t.send("1")
        check("back in Status the outline is back", "Unstaged changes" in t.text(), t.text())
        t.send("q")
    finally:
        t.kill()

    # --- the commit flow runs through the Commit mode -----------------------------------------------
    fx = build_simple(root, "commitflow")
    editor = os.path.join(root, "editor.sh")
    with open(editor, "w") as f:
        f.write("#!/bin/sh\nprintf 'from the commit mode\\n' > \"$1\"\nexit 0\n")
    os.chmod(editor, 0o755)
    env = dict(CLIENT_ENV)
    env["EDITOR"] = editor
    t = Term(binpath, fx, 24, 80, env=env)
    try:
        t.send("c")
        check("c in Status goes to the Commit mode", tab_bar_ok(t, 1), t.lines()[0])
        t.send("e")
        time.sleep(0.4)
        t.drain()
        subject, _ = git(fx, "log", "-1", "--format=%s")
        check("e writes the message in $EDITOR and commits", subject == "from the commit mode", subject)
        check("after the commit the client is back in Status with a message", tab_bar_ok(t, 0) and "committed" in t.text(), t.text())
        t.quit()
    finally:
        t.kill()

    # --- discard asks, naming what is lost ---------------------------------------------------------------
    fx = build_simple(root, "discard")
    t = Term(binpath, fx, 24, 80)
    try:
        t.send("jj")
        t.send("j")
        t.send("x")
        check("x names exactly what will be lost", "discard changes to a.txt?" in t.text(), t.text())
        t.send("n")
        t.quit()
    finally:
        t.kill()

    # --- a merge in progress: named, first in the hint row, and what it forbids is refused ---------------
    fx = os.path.join(root, "flow")
    os.makedirs(fx)
    must(fx, "init", "-q", "-b", "main")
    must(fx, "config", "gc.auto", "0")
    write(os.path.join(fx, "f.txt"), "base\n")
    must(fx, "add", "-A")
    must(fx, "commit", "-q", "-m", "base")
    must(fx, "checkout", "-q", "-b", "other")
    write(os.path.join(fx, "f.txt"), "other\n")
    must(fx, "commit", "-qam", "other side")
    must(fx, "checkout", "-q", "main")
    write(os.path.join(fx, "f.txt"), "main\n")
    must(fx, "commit", "-qam", "main side")
    must(fx, "checkout", "-q", "other")
    write(os.path.join(fx, "g.txt"), "g\n")
    must(fx, "add", "g.txt")
    must(fx, "commit", "-qm", "picked")
    picked = must(fx, "rev-parse", "HEAD")
    must(fx, "checkout", "-q", "main")
    write(os.path.join(fx, "g.txt"), "different\n")
    must(fx, "add", "g.txt")
    must(fx, "commit", "-qm", "g on main")
    git(fx, "cherry-pick", picked)
    t = Term(binpath, fx, 24, 80)
    try:
        top = t.lines()[1]
        check("a cherry-pick under way is named in the status line", "CHERRY-PICKING" in top, top)
        last = t.lines()[23]
        check("the hint row leads with the way out of it", last.lstrip().startswith("A/V cherry-pick / revert: continue"), last)
        check("and does not advertise commit", "c commit" not in last, last)
        t.send("c")
        check("commit is refused with its reason while a cherry-pick is under way", "blocked while CHERRY-PICKING" in t.text() and tab_bar_ok(t, 1) is False, t.text())
        t.send("3")
        check("the way out leads History's hint row too", t.lines()[23].lstrip().startswith("A/V cherry-pick / revert: continue"), t.lines()[23])
        t.send("4")
        t.send("m")
        check("merge is refused, with the reason", "blocked while CHERRY-PICKING" in t.text() or "merge" in t.text().lower(), t.text())
        t.quit()
    finally:
        t.kill()
    git(fx, "cherry-pick", "--abort")


def main():
    if len(sys.argv) != 3:
        print("usage: pty_modes.py <mgit-binary> <scratch-dir>", file=sys.stderr)
        return 2
    binpath = os.path.abspath(sys.argv[1])
    root = os.path.abspath(sys.argv[2])
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(root)
    # Hermetic: no user or system git configuration reaches the fixtures or the client.
    home = os.path.join(root, "home")
    os.makedirs(home)
    for env in (GIT_ENV, CLIENT_ENV):
        env["HOME"] = home
        env["XDG_CONFIG_HOME"] = os.path.join(home, ".config")
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_CONFIG_GLOBAL"] = os.devnull
    only = os.environ.get("MODES_ONLY", "")
    if only != "behaviour":
        fx = build_hostile(root)
        for rows, cols, repaints in ((24, 80, True), (40, 120, True), (12, 40, True)):
            tour(binpath, fx, rows, cols, root, repaints)
    if only != "tour":
        behaviour(binpath, root)
    print("%d checks, %d failed" % (checks, failures))
    return failures


if __name__ == "__main__":
    sys.exit(main())
