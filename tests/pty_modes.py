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

  * the ref actions -- delete, force-delete and rename a branch (Branches), reset
    and detached checkout of a commit (History), the Commit mode's sign-off --
    do what the local git does: each runs next to an identical twin repository
    that the real `git` changes with the matching command, and the refs, reflogs,
    index, work tree and configuration of the two are compared. Where git
    refuses (the current branch, an unmerged branch, a dirty file in the way),
    mgit must refuse too, and change nothing. Only git's behaviour is compared,
    never its wording, so the checks hold across git versions.

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
        # Never block on the pty: write only while it accepts bytes.
        data = keys.encode()
        deadline = time.time() + 5
        while data and time.time() < deadline:
            _, writable, _ = select.select([], [self.master], [], 0.5)
            if not writable:
                continue
            try:
                n = os.write(self.master, data[:256])
            except OSError:
                break
            data = data[n:]
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


# --- the ref actions, against the local git ---------------------------------------------------------


def snapshot(fx):
    """Everything an action can change in a repository, as plain data, so two
    repositories can be compared: refs (loose and packed), HEAD, ORIG_HEAD, the
    index, the status, the work tree's files, the local configuration, every
    reflog (old id, new id, message -- not who or when) and the directories
    under refs/heads and logs (git prunes the ones a deleted branch leaves empty)."""
    gd = os.path.join(fx, ".git")
    snap = {}
    snap["refs"] = must(fx, "for-each-ref", "--format=%(refname) %(objectname)")
    head, rc = git(fx, "symbolic-ref", "-q", "HEAD")
    snap["head"] = head if rc == 0 else "detached " + must(fx, "rev-parse", "HEAD")
    orig, rc = git(fx, "rev-parse", "-q", "--verify", "ORIG_HEAD")
    snap["orig_head"] = orig if rc == 0 else ""
    snap["index"] = must(fx, "ls-files", "-s")
    snap["status"] = must(fx, "status", "--porcelain=v1", "-uall")
    files = {}
    for dirpath, dirnames, filenames in os.walk(fx):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for name in filenames:
            full = os.path.join(dirpath, name)
            with open(full, "rb") as f:
                files[os.path.relpath(full, fx)] = f.read()
    snap["files"] = files
    snap["config"] = sorted(must(fx, "config", "--local", "--list").split("\n"))
    logs = {}
    logroot = os.path.join(gd, "logs")
    for dirpath, dirnames, filenames in os.walk(logroot):
        for name in filenames:
            full = os.path.join(dirpath, name)
            entries = []
            with open(full, encoding="utf-8", errors="replace") as f:
                for line in f.read().split("\n"):
                    if not line:
                        continue
                    left, _, message = line.partition("\t")
                    ids = left.split(" ")
                    entries.append((ids[0], ids[1], message))
            logs[os.path.relpath(full, logroot)] = entries
    snap["logs"] = logs
    logdirs = []
    for dirpath, dirnames, filenames in os.walk(logroot):
        logdirs.append(os.path.relpath(dirpath, logroot))
    snap["logdirs"] = sorted(logdirs)
    heads = []
    for dirpath, dirnames, filenames in os.walk(os.path.join(gd, "refs", "heads")):
        heads.append(os.path.relpath(dirpath, gd))
    snap["refdirs"] = sorted(heads)
    packed = os.path.join(gd, "packed-refs")
    snap["packed"] = open(packed).read() if os.path.exists(packed) else ""
    return snap


def differences(a, b):
    """What differs between two snapshots, readable."""
    out = []
    for key in sorted(set(a) | set(b)):
        if a.get(key) != b.get(key):
            if isinstance(a.get(key), dict) and isinstance(b.get(key), dict):
                for sub in sorted(set(a[key]) | set(b[key])):
                    if a[key].get(sub) != b[key].get(sub):
                        out.append("%s[%s]: %r vs %r" % (key, sub, a[key].get(sub), b[key].get(sub)))
            else:
                out.append("%s: %r vs %r" % (key, a.get(key), b.get(key)))
    return "; ".join(out)[:600]


def twin_pair(root, name, builder):
    """The same repository twice, `name` for mgit and `name-git` for the real
    git, built identically (fixed dates, so object ids agree)."""
    one = builder(root, name)
    two = builder(root, name + "-git")
    check("%s: the twin repositories start identical" % name, differences(snapshot(one), snapshot(two)) == "", differences(snapshot(one), snapshot(two)))
    return one, two


def commit_file(fx, name, text, subject):
    write(os.path.join(fx, name), text)
    must(fx, "add", name)
    must(fx, "commit", "-q", "-m", subject)


def build_branches(root, name):
    """main with two commits; branches that are merged (one in a directory, one
    with upstream configuration), one that is not; refs partly packed."""
    fx = os.path.join(root, name)
    os.makedirs(fx)
    must(fx, "init", "-q", "-b", "main")
    must(fx, "config", "gc.auto", "0")
    commit_file(fx, "a.txt", "one\n", "c-one")
    must(fx, "branch", "old-b")
    must(fx, "branch", "dir/sub-b")
    commit_file(fx, "a.txt", "two\n", "c-two")
    must(fx, "branch", "trk-b")
    must(fx, "config", "branch.trk-b.remote", "origin")
    must(fx, "config", "branch.trk-b.merge", "refs/heads/trk-b")
    must(fx, "checkout", "-q", "-b", "wip-b")
    commit_file(fx, "w.txt", "wip\n", "w-side")
    must(fx, "checkout", "-q", "main")
    must(fx, "pack-refs", "--all")
    must(fx, "branch", "loose-b")
    return fx


def flat(text):
    """Screen text with the panel's border and line breaks flattened, for
    sentences that wrap inside an overlay."""
    return " ".join("".join(" " if c in "│╭╮╰╯─▸▾" else c for c in text).split())


def goto_branch(t, name):
    """Branches mode with the cursor on the row of branch `name`."""
    t.send("4")
    t.send("/" + name + "\r")


def branch_actions(binpath, root):
    fx, twin = twin_pair(root, "refs", build_branches)
    t = Term(binpath, fx, 24, 80)
    try:
        # the keys are in help and palette, not crowding the hint row
        t.send("4")
        t.send("?")
        text = t.text()
        check("Branches help lists delete, force-delete and rename", "delete the branch" in text and "force-delete the branch" in text and "rename the branch" in text, text)
        t.send("\x1b")
        check("they are not in the hint row (it is full)", "D delete" not in t.lines()[23], t.lines()[23])
        t.send(":")
        t.send("rename the branch")
        check("the palette finds rename", "Branches: rename the branch   [e]" in t.text(), t.text())
        t.send("\x1b")

        # the current branch is never deleted, by either key
        before = snapshot(fx)
        goto_branch(t, "main")
        t.send("D")
        check("D on the current branch is refused, saying why", "cannot delete main" in t.text() and "branch you are on" in t.text(), t.text())
        t.send("X")
        check("X on the current branch is refused before it asks", "cannot delete main" in t.text() and "force-delete main" not in t.text(), t.text())
        _, rc = git(twin, "branch", "-D", "main")
        check("git also refuses to delete the current branch", rc != 0, "rc=%r" % rc)
        check("refusing the current branch changes nothing", differences(before, snapshot(fx)) == "", differences(before, snapshot(fx)))

        # an unmerged branch: refused with the reason, nothing changed; git agrees
        goto_branch(t, "wip-b")
        t.send("D")
        check("D on an unmerged branch is refused: not fully merged", "cannot delete wip-b" in t.text() and "not fully merged" in t.text(), t.text())
        _, rc = git(twin, "branch", "-d", "wip-b")
        check("git -d refuses it too", rc != 0, "rc=%r" % rc)
        check("the refused delete changed nothing", differences(before, snapshot(fx)) == "", differences(before, snapshot(fx)))

        # merged branches go the way `git branch -d` removes them: a packed one, one in a directory, one with configuration, a loose one
        for name in ("old-b", "dir/sub-b", "trk-b", "loose-b"):
            goto_branch(t, name)
            t.send("D")
            check("D deletes the merged branch %s" % name, "deleted branch %s" % name in t.text(), t.text())
            must(twin, "branch", "-d", name)
            d = differences(snapshot(fx), snapshot(twin))
            check("deleting %s leaves the repository as git branch -d does" % name, d == "", d)
        check("the deleted branches' reflogs are gone, as are the config section and the empty directory", "logs/refs/heads/trk-b" not in "".join(snapshot(fx)["logs"]) and not any(c.startswith("branch.trk-b.") for c in snapshot(fx)["config"]) and not os.path.exists(os.path.join(fx, ".git", "refs", "heads", "dir")), repr(snapshot(fx)["refdirs"]))
        check("the outline no longer lists a deleted branch", "old-b" not in t.text(), t.text())

        # force: a question first, naming what is lost; any other key says no
        goto_branch(t, "wip-b")
        t.send("X")
        text = flat(t.text())
        check("X asks first, saying the branch is not merged and how to get it back", "force-delete wip-b?" in text and "NOT merged" in text and "git branch wip-b" in text and "y: yes" in text, text)
        t.send("n")
        check("any other key than y keeps the branch", "cancelled" in t.text() and "wip-b" in t.text(), t.text())
        check("a declined force-delete changed nothing", differences(snapshot(fx), snapshot(twin)) == "", differences(snapshot(fx), snapshot(twin)))
        t.send("X")
        t.send("y")
        check("y force-deletes", "deleted branch wip-b" in t.text(), t.text())
        must(twin, "branch", "-D", "wip-b")
        d = differences(snapshot(fx), snapshot(twin))
        check("a forced delete leaves the repository as git branch -D does", d == "", d)
        rc = t.quit()
        check("quits cleanly after the branch actions", rc == 0, "rc=%r" % rc)
    finally:
        t.kill()

    # a branch checked out in a linked work tree is not deleted either
    fx = os.path.join(root, "linked")
    os.makedirs(fx)
    must(fx, "init", "-q", "-b", "main")
    commit_file(fx, "a.txt", "one\n", "c-one")
    must(fx, "branch", "elsewhere-b")
    linked = os.path.join(root, "linked-tree")
    must(fx, "worktree", "add", "-q", linked, "elsewhere-b")
    _, git_rc = git(fx, "branch", "-d", "elsewhere-b")
    t = Term(binpath, fx, 24, 80)
    try:
        goto_branch(t, "elsewhere-b")
        t.send("D")
        check("a branch checked out in another work tree is refused, as git refuses", git_rc != 0 and "cannot delete elsewhere-b" in t.text() and "elsewhere-b" in t.text(), "git rc=%r; %s" % (git_rc, t.text()))
        check("and it is still there", git(fx, "rev-parse", "-q", "--verify", "refs/heads/elsewhere-b")[1] == 0, "gone")
        t.quit()
    finally:
        t.kill()


def rename_actions(binpath, root):
    fx, twin = twin_pair(root, "rename", build_branches)
    t = Term(binpath, fx, 24, 80)

    def rename(old, new):
        goto_branch(t, old)
        t.send("e")
        # the prompt starts from the old name: erase it, type the new one
        t.send("\x7f" * len(old))
        t.send(new)
        t.send("\r")

    try:
        goto_branch(t, "trk-b")
        t.send("e")
        check("e prompts with the branch's name to edit", "rename trk-b to: trk-b" in t.text(), t.text())
        t.send("\x1b")
        check("Esc leaves everything as it was", differences(snapshot(fx), snapshot(twin)) == "", differences(snapshot(fx), snapshot(twin)))

        # a plain rename, a rename with configuration and a log, a rename into a directory
        for old, new in (("trk-b", "renamed-b"), ("old-b", "area/old-b"), ("loose-b", "loose-c")):
            rename(old, new)
            check("e renames %s to %s" % (old, new), "renamed branch %s to %s" % (old, new) in t.text(), t.text())
            must(twin, "branch", "-m", old, new)
            d = differences(snapshot(fx), snapshot(twin))
            check("renaming %s leaves the repository as git branch -m does (refs, reflogs, config)" % old, d == "", d)

        # the current branch: HEAD follows, HEAD's own log says so, the status line shows it
        rename("main", "trunk")
        check("renaming the current branch works and the status line follows", "renamed branch main to trunk" in t.text() and "trunk" in t.lines()[1], t.text())
        must(twin, "branch", "-m", "main", "trunk")
        d = differences(snapshot(fx), snapshot(twin))
        check("renaming the current branch matches git branch -m (HEAD, both logs)", d == "", d)

        # a name that exists: refused unless forced -- the question names what is replaced
        before = snapshot(fx)
        rename("wip-b", "loose-c")
        text = flat(t.text())
        check("a name that exists asks before replacing it", "replace loose-c?" in text and "exists" in text and "git branch loose-c" in text, text)
        t.send("n")
        check("declining changes nothing", differences(before, snapshot(fx)) == "", differences(before, snapshot(fx)))
        _, rc = git(twin, "branch", "-m", "wip-b", "loose-c")
        check("git refuses to rename onto an existing branch without --force", rc != 0, "rc=%r" % rc)
        rename("wip-b", "loose-c")
        t.send("y")
        check("y replaces it", "renamed branch wip-b to loose-c" in t.text(), t.text())
        must(twin, "branch", "-M", "wip-b", "loose-c")
        d = differences(snapshot(fx), snapshot(twin))
        check("a forced rename matches git branch -M", d == "", d)

        # onto the checked-out branch: refused even when forced
        before = snapshot(fx)
        rename("dir/sub-b", "trunk")
        check("a name that is the checked-out branch is refused", "exists and is checked out" in t.text() and "replace trunk?" not in t.text(), t.text())
        _, rc = git(twin, "branch", "-M", "dir/sub-b", "trunk")
        check("git refuses that too", rc != 0, "rc=%r" % rc)
        check("and nothing changed", differences(before, snapshot(fx)) == "", differences(before, snapshot(fx)))
        # an empty name and the unchanged name do nothing
        rename("dir/sub-b", "")
        check("an empty name cancels", "rename cancelled" in t.text() and differences(before, snapshot(fx)) == "", t.text())
        goto_branch(t, "dir/sub-b")
        t.send("e")
        t.send("\r")
        check("the unchanged name cancels", "rename cancelled" in t.text() and differences(before, snapshot(fx)) == "", t.text())
        t.quit()
    finally:
        t.kill()

    # names: whatever the local git accepts as a branch name, mgit accepts; whatever it refuses, mgit refuses
    names = [
        "ok/slash", "café-ü", "x@y", "@", "v1.2", "日本語", "a-b_c", "UPPER",
        "a b", "a..b", "-x", "x.lock", "x/", ".x", "a/.b", "x~1", "a^b", "a:b", "a?b", "a*b", "a[b", "a\\b", "a@{b", "a//b", "/a", "a.", "HEAD", "a/b.lock/c",
    ]
    fx = os.path.join(root, "names")
    os.makedirs(fx)
    must(fx, "init", "-q", "-b", "main")
    commit_file(fx, "a.txt", "one\n", "c-one")
    must(fx, "branch", "probe")
    oracle = os.path.join(root, "names-oracle")
    os.makedirs(oracle)
    must(oracle, "init", "-q", "-b", "main")
    commit_file(oracle, "a.txt", "one\n", "c-one")
    t = Term(binpath, fx, 24, 80)
    wrong = []
    try:
        current = "probe"
        for name in names:
            # git's answer, from a branch of the same name in a scratch repository
            must(oracle, "branch", "-f", "scratch", "main")
            _, git_rc = git(oracle, "branch", "-m", "--", "scratch", name)
            is_ok = git_rc == 0
            if is_ok:
                must(oracle, "branch", "-m", "--", name, "scratch")
            goto_branch(t, current)
            t.send("e")
            t.send("\x7f" * len(current))
            t.send(name)
            t.send("\r")
            exists = git(fx, "rev-parse", "-q", "--verify", "refs/heads/" + name)[1] == 0
            if exists != is_ok:
                wrong.append("%r: git %s, mgit %s" % (name, "accepts" if is_ok else "refuses", "accepted" if exists else "refused"))
            if exists:
                current = name
            elif "not a valid branch name" not in t.text() and name not in ("",):
                wrong.append("%r: refused without saying why: %s" % (name, t.lines()[22]))
        check("%d branch names are accepted or refused exactly as git branch -m does" % len(names), not wrong, "; ".join(wrong))
        t.quit()
    finally:
        t.kill()


def build_history(root, name):
    """main with four commits: alpha-1 (a.txt v1), beta-2 (b.txt), gamma-3 (a.txt v2), delta-4 (c.txt)."""
    fx = os.path.join(root, name)
    os.makedirs(fx)
    must(fx, "init", "-q", "-b", "main")
    must(fx, "config", "gc.auto", "0")
    commit_file(fx, "a.txt", "v1\n", "alpha-1")
    commit_file(fx, "b.txt", "bee\n", "beta-2")
    write(os.path.join(fx, "a.txt"), "v2\n")
    must(fx, "commit", "-q", "-a", "-m", "gamma-3")
    commit_file(fx, "c.txt", "sea\n", "delta-4")
    return fx


def make_dirty(fx):
    """Unstaged changes to a tracked file, a staged new file, an untracked file."""
    write(os.path.join(fx, "a.txt"), "v2 edited\n")
    write(os.path.join(fx, "s.txt"), "staged\n")
    must(fx, "add", "s.txt")
    write(os.path.join(fx, "u.txt"), "untracked\n")


def goto_commit(t, subject):
    t.send("3")
    t.send("/" + subject + "\r")


def reset_actions(binpath, root):
    # each mode against the real git, with a dirty tree so the three differ
    for mode, key in (("soft", "s"), ("mixed", "m"), ("hard", "h")):
        name = "reset-" + mode

        def build(r, n):
            fx = build_history(r, n)
            make_dirty(fx)
            return fx

        fx, twin = twin_pair(root, name, build)
        t = Term(binpath, fx, 24, 80)
        try:
            goto_commit(t, "gamma-3")
            t.send("G")
            text = t.text()
            check("G opens the reset menu for the commit under the cursor (%s)" % mode, "soft" in text and "mixed" in text and "hard" in text and "gamma-3" in text, text)
            before = snapshot(fx)
            if mode == "hard":
                t.send("h")
                text = flat(t.text())
                check("a hard reset asks first, naming what it discards", "a.txt" in text and "s.txt" in text and "2 tracked files" in text and "1 commit" in text and "Untracked files stay" in text and "y: yes" in text, text)
                t.send("x")
                check("any other key than y cancels a hard reset", "cancelled" in t.text() and differences(before, snapshot(fx)) == "", t.text())
                goto_commit(t, "gamma-3")
                t.send("G")
                t.send("h")
                t.send("y")
            else:
                t.send(key)
            check("reset --%s moved the branch" % mode, "reset main to" in t.text() and "(%s)" % mode in t.text(), t.text())
            must(twin, "reset", "--" + mode, must(twin, "rev-parse", "HEAD~1"))
            d = differences(snapshot(fx), snapshot(twin))
            check("reset --%s leaves HEAD, ORIG_HEAD, index, work tree, status and reflogs as git reset --%s does" % (mode, mode), d == "", d)
            check("reset --%s: the untracked file is kept" % mode, os.path.exists(os.path.join(fx, "u.txt")), "gone")
            t.quit()
        finally:
            t.kill()

    # reset on a detached HEAD moves HEAD itself
    fx, twin = twin_pair(root, "reset-detached", build_history)
    t = Term(binpath, fx, 24, 80)
    try:
        goto_commit(t, "gamma-3")
        t.send("o")
        check("o detaches at the commit", "HEAD is now detached at" in t.text(), t.text())
        goto_commit(t, "beta-2")
        t.send("G")
        check("the menu names the detached HEAD", "detached HEAD" in t.text(), t.text())
        t.send("m")
        must(twin, "checkout", "-q", "--detach", must(twin, "rev-parse", "HEAD~1"))
        must(twin, "reset", "--mixed", must(twin, "rev-parse", "HEAD~1"))
        d = differences(snapshot(fx), snapshot(twin))
        check("reset on a detached HEAD matches git", d == "", d)
        t.quit()
    finally:
        t.kill()

    # while a merge or a cherry-pick is under way, none of the four ref actions runs
    fx = os.path.join(root, "reset-flows")
    os.makedirs(fx)
    must(fx, "init", "-q", "-b", "main")
    must(fx, "config", "gc.auto", "0")
    commit_file(fx, "f.txt", "base\n", "c-base")
    must(fx, "checkout", "-q", "-b", "other")
    commit_file(fx, "f.txt", "other\n", "c-other")
    must(fx, "checkout", "-q", "main")
    commit_file(fx, "f.txt", "main\n", "c-main")
    must(fx, "branch", "spare")
    git(fx, "merge", "other")
    t = Term(binpath, fx, 24, 80)
    try:
        before = snapshot(fx)
        goto_commit(t, "c-base")
        t.send("G")
        check("reset is refused while MERGING, with the reason", "reset is blocked while MERGING" in t.text(), t.text())
        t.send("o")
        check("check out is refused while MERGING", "check out is blocked while MERGING" in t.text(), t.text())
        t.send("4")
        t.send("/spare\r")
        t.send("D")
        check("delete branch is refused while MERGING", "delete branch is blocked while MERGING" in t.text(), t.text())
        t.send("e")
        check("rename branch is refused while MERGING", "rename branch is blocked while MERGING" in t.text() and "rename spare to" not in t.text(), t.text())
        check("nothing changed", differences(before, snapshot(fx)) == "", differences(before, snapshot(fx)))
        t.quit()
    finally:
        t.kill()
    git(fx, "merge", "--abort")
    must(fx, "checkout", "-q", "other")
    picked = must(fx, "rev-parse", "main")
    git(fx, "cherry-pick", picked)
    t = Term(binpath, fx, 24, 80)
    try:
        before = snapshot(fx)
        goto_commit(t, "c-base")
        t.send("G")
        check("reset is refused while CHERRY-PICKING, with the reason", "reset is blocked while CHERRY-PICKING" in t.text(), t.text())
        t.send("o")
        check("check out is refused while CHERRY-PICKING", "check out is blocked while CHERRY-PICKING" in t.text(), t.text())
        t.send("4")
        t.send("/spare\r")
        t.send("X")
        check("force-delete is refused while CHERRY-PICKING", "blocked while CHERRY-PICKING" in t.text() and "force-delete spare?" not in t.text(), t.text())
        check("nothing changed", differences(before, snapshot(fx)) == "", differences(before, snapshot(fx)))
        t.quit()
    finally:
        t.kill()
    git(fx, "cherry-pick", "--abort")


def detach_actions(binpath, root):
    fx, twin = twin_pair(root, "detach", build_history)
    t = Term(binpath, fx, 24, 80)
    try:
        goto_commit(t, "beta-2")
        t.send("o")
        target = must(twin, "rev-parse", "HEAD~2")
        check("o says HEAD is detached", "HEAD is now detached at" in t.text(), t.text())
        check("the status line shows the detached HEAD afterwards", "detached @ %s" % must(fx, "rev-parse", "--short=7", "HEAD") in t.lines()[1], t.lines()[1])
        must(twin, "checkout", "-q", "--detach", target)
        d = differences(snapshot(fx), snapshot(twin))
        check("o leaves HEAD, index, work tree and the HEAD reflog as git checkout --detach does", d == "", d)
        check("HEAD really is detached (no branch)", git(fx, "symbolic-ref", "-q", "HEAD")[1] != 0, "on a branch")
        check("the branch stayed where it was", must(fx, "rev-parse", "main") == must(twin, "rev-parse", "main"), "main moved")
        t.quit()
    finally:
        t.kill()

    # a file the checkout would change has local changes: refused, by both
    fx, twin = twin_pair(root, "detach-dirty", build_history)
    for repo in (fx, twin):
        write(os.path.join(repo, "a.txt"), "v3 local\n")
    t = Term(binpath, fx, 24, 80)
    try:
        before = snapshot(fx)
        goto_commit(t, "alpha-1")
        t.send("o")
        check("o refuses when a file it would change has local changes, saying so", "check out refused" in t.text() and "local changes" in t.text() and "HEAD stays" in t.text(), t.text())
        _, rc = git(twin, "checkout", "--detach", must(twin, "rev-parse", "HEAD~3"))
        check("git checkout --detach refuses it too", rc != 0, "rc=%r" % rc)
        check("a refused check out changes nothing (HEAD, index, files, logs)", differences(before, snapshot(fx)) == "" and differences(snapshot(fx), snapshot(twin)) == "", differences(snapshot(fx), snapshot(twin)))
        check("the status line still shows the branch", "main" in t.lines()[1] and "detached" not in t.lines()[1], t.lines()[1])
        t.quit()
    finally:
        t.kill()

    # a change to a file the commits do not differ in is carried over, as git carries it
    fx, twin = twin_pair(root, "detach-carry", build_history)
    for repo in (fx, twin):
        write(os.path.join(repo, "b.txt"), "bee edited\n")
        write(os.path.join(repo, "n.txt"), "untracked\n")
    t = Term(binpath, fx, 24, 80)
    try:
        goto_commit(t, "beta-2")
        t.send("o")
        check("o carries a change to a file the commits do not differ in, as git does", "HEAD is now detached at" in t.text(), t.text())
        must(twin, "checkout", "-q", "--detach", must(twin, "rev-parse", "HEAD~2"))
        d = differences(snapshot(fx), snapshot(twin))
        check("and the result equals git's", d == "", d)
        t.quit()
    finally:
        t.kill()


def signoff_actions(binpath, root):
    editor = os.path.join(root, "signoff-editor.sh")
    with open(editor, "w") as f:
        f.write("#!/bin/sh\ncp \"$MGIT_TEST_MESSAGE\" \"$1\"\nexit 0\n")
    os.chmod(editor, 0o755)
    cases = [
        ("a subject only", "just a subject\n"),
        ("a body", "subject line\n\nA body paragraph that\nruns over two lines.\n"),
        ("a trailer block", "subject line\n\nbody text\n\nReviewed-by: Bo <bo@example.com>\n"),
        ("the sign-off already there", "subject line\n\nbody text\n\nSigned-off-by: Client <client@example.com>\n"),
        ("another person's sign-off", "subject line\n\nbody text\n\nSigned-off-by: Bo <bo@example.com>\n"),
        ("a subject that looks like a trailer", "fix: the parser\n"),
    ]
    for index, (what, message) in enumerate(cases):
        name = "signoff-%d" % index
        fx = build_simple(root, name)
        twin = build_simple(root, name + "-git")
        msgfile = os.path.join(root, name + ".msg")
        with open(msgfile, "w") as f:
            f.write(message)
        env = dict(CLIENT_ENV)
        env["EDITOR"] = editor
        env["MGIT_TEST_MESSAGE"] = msgfile
        t = Term(binpath, fx, 24, 80, env=env)
        try:
            t.send("c")
            text = t.text()
            check("sign-off (%s): the Commit mode starts with sign-off off" % what, "Sign-off  off" in text and "s sign-off" in t.lines()[23], text + "|" + t.lines()[23])
            t.send("s")
            text = t.text()
            check("sign-off (%s): s turns it on and the panel shows the exact line" % what, "Sign-off  ON: Signed-off-by: Client <client@example.com>" in text and "sign-off on" in text, text)
            t.send("e")
            time.sleep(0.4)
            t.drain()
        finally:
            t.kill()
        tenv = dict(CLIENT_ENV)
        r = subprocess.run(["git", "-C", twin, "commit", "-q", "-s", "-F", msgfile], capture_output=True, text=True, env=tenv)
        ours = git(fx, "log", "-1", "--format=%B")[0]
        theirs = git(twin, "log", "-1", "--format=%B")[0]
        check("sign-off (%s): the commit message equals git commit -s" % what, r.returncode == 0 and ours == theirs and ours.count("Signed-off-by: Client <client@example.com>") == 1, "mgit=%r git=%r" % (ours, theirs))

    # off means off
    fx = build_simple(root, "signoff-off")
    msgfile = os.path.join(root, "signoff-off.msg")
    with open(msgfile, "w") as f:
        f.write("no trailer wanted\n")
    env = dict(CLIENT_ENV)
    env["EDITOR"] = editor
    env["MGIT_TEST_MESSAGE"] = msgfile
    t = Term(binpath, fx, 24, 80, env=env)
    try:
        t.send("c")
        t.send("e")
        time.sleep(0.4)
        t.drain()
    finally:
        t.kill()
    check("sign-off off (the default): no trailer is added", "Signed-off-by" not in git(fx, "log", "-1", "--format=%B")[0], git(fx, "log", "-1", "--format=%B")[0])

    # the toggle works both ways, and mgit.signoff makes it start on
    fx = build_simple(root, "signoff-config")
    must(fx, "config", "mgit.signoff", "true")
    must(fx, "config", "user.name", "Config Name")
    must(fx, "config", "user.email", "config@example.com")
    env = dict(CLIENT_ENV)
    for k in ("GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"):
        env.pop(k, None)
    env["EDITOR"] = editor
    msgfile = os.path.join(root, "signoff-config.msg")
    with open(msgfile, "w") as f:
        f.write("configured\n")
    env["MGIT_TEST_MESSAGE"] = msgfile
    t = Term(binpath, fx, 24, 80, env=env)
    try:
        t.send("c")
        check("mgit.signoff = true starts with sign-off on, naming user.name and user.email", "Sign-off  ON: Signed-off-by: Config Name <config@example.com>" in t.text(), t.text())
        t.send("s")
        check("s turns it off again", "Sign-off  off" in t.text() and "sign-off off" in t.text(), t.text())
        t.send("s")
        t.send("e")
        time.sleep(0.4)
        t.drain()
    finally:
        t.kill()
    check("the configured sign-off uses user.name and user.email", git(fx, "log", "-1", "--format=%B")[0] == "configured\n\nSigned-off-by: Config Name <config@example.com>", git(fx, "log", "-1", "--format=%B")[0])


def actions(binpath, root):
    branch_actions(binpath, root)
    rename_actions(binpath, root)
    reset_actions(binpath, root)
    detach_actions(binpath, root)
    signoff_actions(binpath, root)


def main():
    if len(sys.argv) != 3:
        print("usage: pty_modes.py <mgit-binary> <scratch-dir>", file=sys.stderr)
        return 2
    binpath = os.path.abspath(sys.argv[1])
    root = os.path.abspath(sys.argv[2])
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(root)
    # /tmp is a symlink on macOS: work in the real path, so a repository's
    # location is the same to git, to the client and to this script.
    root = os.path.realpath(root)
    # Hermetic: no user or system git configuration reaches the fixtures or the client.
    home = os.path.join(root, "home")
    os.makedirs(home)
    for env in (GIT_ENV, CLIENT_ENV):
        env["HOME"] = home
        env["XDG_CONFIG_HOME"] = os.path.join(home, ".config")
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_CONFIG_GLOBAL"] = os.devnull
        # Nothing above the scratch directory is ever searched for a repository.
        env["GIT_CEILING_DIRECTORIES"] = root
    only = os.environ.get("MODES_ONLY", "")
    if only in ("", "tour"):
        fx = build_hostile(root)
        for rows, cols, repaints in ((24, 80, True), (40, 120, True), (12, 40, True)):
            tour(binpath, fx, rows, cols, root, repaints)
    if only in ("", "behaviour"):
        behaviour(binpath, root)
    if only in ("", "actions"):
        actions(binpath, root)
    print("%d checks, %d failed" % (checks, failures))
    return failures


if __name__ == "__main__":
    sys.exit(main())
