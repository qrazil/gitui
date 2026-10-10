#!/usr/bin/env python3
"""The rebase UI of the compiled `ourgitui`, driven under a real pty against
disposable git fixtures this script builds and destroys itself. Real `git` is
the oracle both ways: every flow is run in a copy of the same fixture with
`git rebase` (interactive ones with a GIT_SEQUENCE_EDITOR script) and compared
by trees, authors and messages; `git fsck --strict` and the reflog are read
back; and rebases that git started are finished in the UI and the other way
round. (Commit ids differ: the client commits under its own identity.)

    python3 tests/pty_rebase.py <ourgitui-binary> <scratch-dir>

Every `ok` / `FAIL` line is one check; the exit status says whether any failed.
"""
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pty_e2e as P  # noqa: E402  (main() there is guarded)
import pty_merge as M  # noqa: E402  (main() there is guarded)

failures = 0
passed = 0


def check(name, condition, detail=""):
    global failures, passed
    if condition:
        passed += 1
        print("ok   " + name)
    else:
        failures += 1
        print("FAIL " + name + ": " + detail)


def git(fx, *args, env=None):
    return P.git(fx, *args, env=env if env is not None else P.GIT_ENV)


def out(fx, *args):
    return git(fx, *args)[0]


def write(fx, name, text):
    with open(os.path.join(fx, name), "w") as f:
        f.write(text)


def read(fx, name):
    with open(os.path.join(fx, name)) as f:
        return f.read()


def commit_all(fx, message):
    git(fx, "add", "-A")
    git(fx, "commit", "-q", "-m", message)


def fsck_clean(fx):
    o, e, rc = git(fx, "fsck", "--strict")
    return rc == 0 and "error" not in o + e


def has(fx, name):
    return os.path.exists(os.path.join(fx, ".git", name))


def script(path, body):
    with open(path, "w") as f:
        f.write("#!/bin/sh\n" + body + "\n")
    os.chmod(path, 0o755)


def todo_script(path, py):
    """A GIT_SEQUENCE_EDITOR that rewrites the todo lines with python source `py`
    (it sees `lines`, a list of strings without newlines, and sets `lines`)."""
    with open(path, "w") as f:
        f.write("#!/usr/bin/env python3\nimport sys\nlines = open(sys.argv[1]).read().split('\\n')\nlines = [l for l in lines if l and not l.startswith('#')]\n" + py + "\nopen(sys.argv[1], 'w').write('\\n'.join(lines) + '\\n')\n")
    os.chmod(path, 0o755)


def chain(fx, rev="HEAD"):
    return out(fx, "log", "--format=%T|%an|%s", rev)


def full_chain(fx, rev="HEAD"):
    return out(fx, "log", "--format=%T|%an|%B%x00", rev)


BASE = "a\nb\nc\nd\ne\nf\ng\nh\n"


def build(root, name):
    """base (f, k); main: m1 (adds m, f line 3 = OURS); feature (off base):
    ca cb cc, each adding a file; conf (off base): x1 adds x, x2 sets f line 3
    to THEIRS (conflicts with m1), x3 adds y. HEAD ends on feature."""
    fx = P.make_fixture(root, name)
    git(fx, "config", "merge.renames", "false")
    write(fx, "f", BASE)
    write(fx, "k", "k\n")
    commit_all(fx, "base")
    git(fx, "tag", "t0")
    git(fx, "checkout", "-q", "-b", "feature")
    for n in "abc":
        write(fx, "file_" + n, n + "\n")
        commit_all(fx, "c" + n)
    git(fx, "checkout", "-q", "-b", "conf", "t0")
    write(fx, "x", "x\n")
    commit_all(fx, "x1")
    write(fx, "f", "a\nb\nTHEIRS\nd\ne\nf\ng\nh\n")
    commit_all(fx, "x2")
    write(fx, "y", "y\n")
    commit_all(fx, "x3")
    git(fx, "checkout", "-q", "main")
    write(fx, "f", "a\nb\nOURS\nd\ne\nf\ng\nh\n")
    write(fx, "m", "m\n")
    commit_all(fx, "m1")
    git(fx, "checkout", "-q", "feature")
    return fx


def twin(fx, root, name):
    dest = os.path.join(root, name)
    P.copy_repo(fx, dest)
    return dest


def rebase_env(extra=None):
    env = dict(P.GIT_ENV)
    env["GIT_EDITOR"] = "true"
    env["GIT_SEQUENCE_EDITOR"] = "true"
    if extra:
        env.update(extra)
    return env


def git_rebase(fx, *args, **env):
    r = subprocess.run(["git", "-C", fx, "rebase"] + list(args), capture_output=True, text=True, env=rebase_env(env))
    return r


def ed_env(path):
    env = P.env_with_editor(path)
    env.pop("GIT_EDITOR", None)
    env.pop("VISUAL", None)
    return env


def cursor_to(s, needle):
    """Select the outline row containing `needle`."""
    for _ in range(14):
        s.send("k")
    lines = s.text().split("\n")
    first = 1
    for i, ln in enumerate(lines):
        if needle in ln and ln.startswith("│"):
            for _ in range(i - first):
                s.send("j")
            return True
    return False


def pick(s, key, branch):
    """`r <key>`, then the picker: type the name and choose it."""
    s.send("r")
    s.send(key)
    s.send(branch)
    s.send("\r")


def same(fx, other, what, rev="HEAD", full=False):
    f = full_chain if full else chain
    a, b = f(fx, rev), f(other, rev)
    check(what + ": trees, authors and messages equal git's", a == b and a != "", "ours:\n%s\ngit:\n%s" % (a, b))


def reflog_of(fx, ref):
    return out(fx, "reflog", "show", "--format=%gs", ref).split("\n")


def main():
    if len(sys.argv) != 3:
        print("usage: pty_rebase.py <ourgitui-binary> <scratch-dir>", file=sys.stderr)
        return 2
    binpath = os.path.abspath(sys.argv[1])
    root = os.path.abspath(sys.argv[2])
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(root)

    # --- the menu and its toggles ----------------------------------------------------
    fx = build(root, "menu")
    s = P.Session(binpath, fx)
    s.send("r")
    t = s.text()
    check(
        "menu: r opens the rebase menu with its keys and both toggles off",
        all(w in t for w in ("rebase the current branch onto a branch you pick", "rebase -i onto", "from the commit under the cursor", "--onto", "autosquash off", "autostash off")),
        t,
    )
    s.send("s")
    s.send("a")
    check("menu: s and a toggle autosquash and autostash on, the menu stays open", "autosquash on" in s.text() and "autostash on" in s.text(), s.text())
    s.send("s")
    check("menu: s again turns autosquash off", "autosquash off" in s.text() and "autostash on" in s.text(), s.text())
    s.send("\x1b")
    check("menu: Escape closes it", "rebase  [" not in s.text(), s.text())
    s.send("r")
    s.send("r")
    t = s.text()
    check("menu: r r opens the branch picker, listing main", "rebase onto" in t and "main" in t, t)
    s.send("\x1b")
    s.quit()

    # --- a linear rebase, and Z undoing it as one step --------------------------------
    fx = build(root, "linear")
    other = twin(fx, root, "linear_git")
    orig_tip = out(fx, "rev-parse", "HEAD")
    git_rebase(other, "main")
    s = P.Session(binpath, fx)
    pick(s, "r", "main")
    t = s.text()
    check("linear: the status line says the rebase finished", "rebase finished" in t, t)
    same(fx, other, "linear: rebase onto main")
    check("linear: HEAD is still on feature, clean, nothing in progress, fsck --strict clean", out(fx, "symbolic-ref", "--short", "HEAD") == "feature" and out(fx, "status", "--short") == "" and not has(fx, "rebase-merge") and fsck_clean(fx), out(fx, "status", "--short"))
    check("linear: the branch reflog lines equal git's", reflog_of(fx, "feature") == reflog_of(other, "feature"), "%r vs %r" % (reflog_of(fx, "feature"), reflog_of(other, "feature")))
    check("linear: the HEAD reflog lines equal git's", reflog_of(fx, "HEAD") == reflog_of(other, "HEAD"), "%r vs %r" % (reflog_of(fx, "HEAD"), reflog_of(other, "HEAD")))
    s.send("@")
    check("linear: the command log records 'rebase main'", "rebase main" in s.text(), s.text())
    s.send("\x1b")
    s.send("Z")
    t = s.text()
    check("undo: Z offers the whole rebase as one step", "rebase (finish)" in t and "reset branch feature to " + orig_tip[:7] in t, t)
    s.send("y")
    check("undo: y puts the branch back at its pre-rebase tip, tree clean, fsck clean", out(fx, "rev-parse", "feature") == orig_tip and out(fx, "status", "--short") == "" and fsck_clean(fx), out(fx, "rev-parse", "feature"))
    s.quit()

    # --- up to date: nothing to do ------------------------------------------------------
    fx = build(root, "uptodate")
    git(fx, "branch", "basis", "t0")
    git(fx, "checkout", "-q", "main")
    before = out(fx, "rev-parse", "HEAD")
    s = P.Session(binpath, fx)
    pick(s, "r", "basis")
    check("up to date: rebasing main onto an ancestor changes nothing", out(fx, "rev-parse", "HEAD") == before and not has(fx, "rebase-merge") and "up to date" in s.text(), s.text())
    s.quit()

    # --- the todo editor ------------------------------------------------------------------
    fx = build(root, "todo")
    other = twin(fx, root, "todo_git")
    seq = os.path.join(root, "seq_reorder.py")
    todo_script(seq, "lines = [lines[0], lines[2], 'drop' + lines[1][4:]]")
    git_rebase(other, "-i", "main", GIT_SEQUENCE_EDITOR=seq)
    s = P.Session(binpath, fx)
    pick(s, "i", "main")
    t = s.text()
    check("todo: r i main opens the editor with one pick line per commit, oldest first", "rebase -i onto main (3 commits)" in t and t.index(" ca") < t.index(" cb") < t.index(" cc") and t.count("pick ") == 3, t)
    s.send("j")
    s.send("d")
    s.send("J")
    t = s.text()
    check("todo: j d J drops the second line and moves it down", t.index(" cc") < t.index("drop ") and "drop " in t and t.count("pick ") == 2, t)
    s.send("\r")
    check("todo: Enter starts it; dropping and reordering equal git's", out(fx, "log", "--format=%s", "main..HEAD").split("\n") == ["cc", "ca"], out(fx, "log", "--format=%s", "main..HEAD"))
    same(fx, other, "todo: reordered and dropped")
    s.quit()

    fx = build(root, "todo_cancel")
    before = out(fx, "rev-parse", "HEAD")
    s = P.Session(binpath, fx)
    pick(s, "i", "main")
    s.send("d")
    s.send("\x1b")
    check("todo: Escape cancels, nothing changed", out(fx, "rev-parse", "HEAD") == before and not has(fx, "rebase-merge") and "rebase -i onto" not in s.text(), s.text())
    s.quit()

    fx = build(root, "todo_all_squash")
    s = P.Session(binpath, fx)
    pick(s, "i", "main")
    s.send("s")
    s.send("\r")
    check("todo: a squash on the first line is refused and the editor stays", "squash" in s.text() and "rebase -i onto" in s.text() and not has(fx, "rebase-merge"), s.text())
    s.send("\x1b")
    s.quit()

    # --- from here -----------------------------------------------------------------------------
    fx = build(root, "here")
    other = twin(fx, root, "here_git")
    seq = os.path.join(root, "seq_drop_first.py")
    todo_script(seq, "lines[0] = 'drop' + lines[0][4:]")
    git_rebase(other, "-i", "feature~1^", GIT_SEQUENCE_EDITOR=seq)
    s = P.Session(binpath, fx)
    cursor_to(s, "cb")
    s.send("r")
    s.send("h")
    t = s.text()
    rows = [ln for ln in t.split("\n") if "pick " in ln]
    check("here: r h on a commit row opens the todo list from that commit on", "(2 commits)" in t and len(rows) == 2 and " cb" in rows[0] and " cc" in rows[1], t)
    s.send("d")
    s.send("\r")
    same(fx, other, "here: drop the first of the commits from here on")
    s.quit()

    # --- --onto ----------------------------------------------------------------------------------
    fx = build(root, "onto")
    other = twin(fx, root, "onto_git")
    git(fx, "branch", "mid", "feature~1")
    git(other, "branch", "mid", "feature~1")
    git_rebase(other, "--onto", "main", "mid")
    s = P.Session(binpath, fx)
    s.send("r")
    s.send("o")
    s.send("main")
    s.send("\r")
    t = s.text()
    check("onto: the second picker names the new base", "--onto main" in t, t)
    s.send("mid")
    s.send("\r")
    same(fx, other, "onto: rebase --onto main mid")
    check("onto: only cc moved", out(fx, "log", "--format=%s", "main..HEAD") == "cc", out(fx, "log", "--format=%s", "main..HEAD"))
    s.quit()

    # --- a conflict: the banner, the block, resolve, continue ---------------------------------
    fx = build(root, "conflict")
    other = twin(fx, root, "conflict_git")
    git(fx, "checkout", "-q", "conf")
    git(other, "checkout", "-q", "conf")
    git_rebase(other, "main")
    git(other, "checkout", "--ours", "f")
    git(other, "add", "f")
    git_rebase(other, "--continue")
    s = P.Session(binpath, fx)
    pick(s, "r", "main")
    t = s.text()
    status = out(fx, "status", "--short")
    check("conflict: the outline shows the REBASING banner and the Unmerged paths section", "REBASING 2/3" in t and "Unmerged paths (1)" in t and "UU  f" in t, t)
    check("conflict: git agrees (UU f, REBASE_HEAD, rebase-merge state)", status == "UU f" and has(fx, "REBASE_HEAD") and has(fx, "rebase-merge"), status)
    check("conflict: the status line says where it stopped", "rebase stopped on" in t and "conflict" in t, t)
    s.send("A")
    check("conflict: cherry-pick is blocked while REBASING", "REBASING 2/3 is under way" in s.text(), s.text())
    s.send("m")
    check("conflict: so is a merge", "merge is blocked while REBASING" in s.text(), s.text())
    cursor_to(s, "UU  f")
    s.send("\r")
    check("conflict: Enter opens the conflict view", "resolve f" in s.text(), s.text())
    s.send("a")
    check("conflict: choosing ours (= HEAD's text) settles the file: nothing left unmerged or staged", out(fx, "status", "--short") == "" and out(fx, "ls-files", "-u") == "", out(fx, "status", "--short"))
    s.send("r")
    t = s.text()
    check("conflict: r during a rebase opens the continue/skip/abort/quit/edit-todo menu", all(w in t for w in ("continue", "skip", "abort", "quit", "edit the todo list")) and "REBASING" in t, t)
    s.send("c")
    t = s.text()
    check("conflict: r c finishes the remaining pick", "rebase finished" in t and "REBASING" not in t and not has(fx, "rebase-merge") and not has(fx, "REBASE_HEAD"), t)
    same(fx, other, "conflict: resolve with ours, continue")
    check("conflict: reflog lines equal git's", reflog_of(fx, "conf") == reflog_of(other, "conf"), "%r vs %r" % (reflog_of(fx, "conf"), reflog_of(other, "conf")))
    check("conflict: fsck --strict clean", fsck_clean(fx))
    s.quit()

    # --- abort ----------------------------------------------------------------------------------------
    fx = build(root, "abort")
    git(fx, "checkout", "-q", "conf")
    orig = out(fx, "rev-parse", "HEAD")
    s = P.Session(binpath, fx)
    pick(s, "r", "main")
    s.send("r")
    s.send("a")
    check("abort: r a asks first", "abort the REBASING" in s.text() and "any other key" in s.text(), s.text())
    s.send("x")
    check("abort: any other key cancels it, the rebase goes on", has(fx, "rebase-merge") and "REBASING" in s.text(), s.text())
    s.send("r")
    s.send("a")
    s.send("y")
    check(
        "abort: y puts the branch, HEAD and files back (state gone, clean, same tip)",
        out(fx, "rev-parse", "HEAD") == orig and out(fx, "symbolic-ref", "--short", "HEAD") == "conf" and not has(fx, "rebase-merge") and not has(fx, "REBASE_HEAD") and out(fx, "status", "--short") == "" and fsck_clean(fx),
        out(fx, "status", "--short"),
    )
    check("abort: the banner is gone", "REBASING" not in s.text(), s.text())
    s.quit()

    # --- skip and quit -----------------------------------------------------------------------------------
    fx = build(root, "skip")
    other = twin(fx, root, "skip_git")
    git(fx, "checkout", "-q", "conf")
    git(other, "checkout", "-q", "conf")
    git_rebase(other, "main")
    git_rebase(other, "--skip")
    s = P.Session(binpath, fx)
    pick(s, "r", "main")
    s.send("r")
    s.send("s")
    check("skip: r s drops the conflicting commit and finishes", "rebase finished" in s.text() and not has(fx, "rebase-merge"), s.text())
    same(fx, other, "skip: skip the conflicting pick")
    s.quit()

    fx = build(root, "quit")
    git(fx, "checkout", "-q", "conf")
    s = P.Session(binpath, fx)
    pick(s, "r", "main")
    head = out(fx, "rev-parse", "HEAD")
    s.send("r")
    s.send("q")
    check("quit: r q forgets the rebase and leaves HEAD where it is", not has(fx, "rebase-merge") and out(fx, "rev-parse", "HEAD") == head and "REBASING" not in s.text(), s.text())
    s.quit()

    # --- edit stop, edit-todo, continue -----------------------------------------------------------------
    fx = build(root, "edit")
    other = twin(fx, root, "edit_git")
    seq = os.path.join(root, "seq_edit.py")
    todo_script(seq, "lines[1] = 'edit' + lines[1][4:]")
    git_rebase(other, "-i", "main", GIT_SEQUENCE_EDITOR=seq)
    seq2 = os.path.join(root, "seq_drop_all.py")
    todo_script(seq2, "lines = ['drop' + l[4:] for l in lines]")
    git_rebase(other, "--edit-todo", GIT_SEQUENCE_EDITOR=seq2)
    git_rebase(other, "--continue")
    s = P.Session(binpath, fx)
    pick(s, "i", "main")
    s.send("j")
    s.send("e")
    s.send("\r")
    t = s.text()
    check("edit: the rebase stops at the edit commit with a banner", "REBASING 2/3" in t and "to edit" in t, t)
    check("edit: git agrees (HEAD is cb on the new base, state present)", has(fx, "rebase-merge") and out(fx, "log", "-1", "--format=%s") == "cb", out(fx, "log", "-1", "--format=%s"))
    s.send("r")
    s.send("e")
    t = s.text()
    check("edit: r e opens the todo list of what is left", "what is left" in t and " cc" in t and " cb" not in t, t)
    s.send("d")
    s.send("\r")
    check("edit: Enter saves it: git sees 'drop' in git-rebase-todo", "drop" in read(fx, ".git/rebase-merge/git-rebase-todo"), read(fx, ".git/rebase-merge/git-rebase-todo"))
    s.send("r")
    s.send("c")
    check("edit: r c finishes", "rebase finished" in s.text() and not has(fx, "rebase-merge"), s.text())
    same(fx, other, "edit: stop at cb, drop cc from the todo, continue")
    s.quit()

    # --- reword and squash through $EDITOR -------------------------------------------------------------------
    fx = build(root, "reword")
    other = twin(fx, root, "reword_git")
    ed = os.path.join(root, "ed_reword.sh")
    script(ed, 'printf "ca, reworded\\n" >"$1"')
    seq = os.path.join(root, "seq_reword.py")
    todo_script(seq, "lines[0] = 'reword' + lines[0][4:]")
    git_rebase(other, "-i", "main", GIT_SEQUENCE_EDITOR=seq, GIT_EDITOR=ed)
    s = P.Session(binpath, fx, env=ed_env(ed))
    pick(s, "i", "main")
    s.send("r")
    s.send("\r")
    time.sleep(0.8)
    s.drain(1.0)
    t = s.text()
    check("reword: $EDITOR is run, the commit gets its new message and the rebase finishes", "rebase finished" in t and not has(fx, "rebase-merge"), t)
    same(fx, other, "reword: first commit reworded", full=True)
    s.quit()

    fx = build(root, "squash")
    other = twin(fx, root, "squash_git")
    seen = os.path.join(root, "seen_squash_msg")
    ed = os.path.join(root, "ed_squash.sh")
    script(ed, 'cp "$1" "%s"; printf "ca and cb\\n" >"$1"' % seen)
    seq = os.path.join(root, "seq_squash.py")
    todo_script(seq, "lines[1] = 'squash' + lines[1][4:]")
    git_rebase(other, "-i", "main", GIT_SEQUENCE_EDITOR=seq, GIT_EDITOR=ed)
    git_seen = open(seen).read()
    os.remove(seen)
    s = P.Session(binpath, fx, env=ed_env(ed))
    pick(s, "i", "main")
    s.send("j")
    s.send("s")
    s.send("\r")
    time.sleep(0.8)
    s.drain(1.0)
    check("squash: the editor starts from git's combined message (without the status comments)", os.path.exists(seen) and open(seen).read() == git_seen.split("#\n# Date:")[0], "%r vs git %r" % (open(seen).read() if os.path.exists(seen) else None, git_seen.split("#\n# Date:")[0]))
    same(fx, other, "squash: ca + cb, one message", full=True)
    check("squash: two commits are left on main", out(fx, "rev-list", "--count", "main..HEAD") == "2", out(fx, "rev-list", "--count", "main..HEAD"))
    s.quit()

    fx = build(root, "fixup")
    other = twin(fx, root, "fixup_git")
    seq = os.path.join(root, "seq_fixup.py")
    todo_script(seq, "lines[2] = 'fixup' + lines[2][4:]")
    git_rebase(other, "-i", "main", GIT_SEQUENCE_EDITOR=seq)
    s = P.Session(binpath, fx)
    pick(s, "i", "main")
    s.send("j")
    s.send("j")
    s.send("f")
    s.send("\r")
    same(fx, other, "fixup: cc melded into cb, no editor", full=True)
    s.quit()

    # --- autosquash ----------------------------------------------------------------------------------------------
    fx = build(root, "autosquash")
    git(fx, "checkout", "-q", "feature")
    write(fx, "file_a", "a, fixed\n")
    commit_all(fx, "fixup! ca")
    other = twin(fx, root, "autosquash_git")
    git_rebase(other, "-i", "--autosquash", "main")
    s = P.Session(binpath, fx)
    s.send("r")
    s.send("s")
    s.send("i")
    s.send("main")
    s.send("\r")
    t = s.text()
    check("autosquash: with s on, the fixup! line is moved under its target and set to fixup", "fixup " in t and t.index(" ca") < t.index("fixup "), t)
    s.send("\r")
    same(fx, other, "autosquash: fixup! ca folded into ca", full=True)
    s.quit()

    # --- autostash ----------------------------------------------------------------------------------------------------
    fx = build(root, "stash_refused")
    write(fx, "k", "k dirty\n")
    before = out(fx, "rev-parse", "HEAD")
    s = P.Session(binpath, fx)
    pick(s, "r", "main")
    check("autostash: without it a dirty tree refuses the rebase and nothing changes", "refused" in s.text() and out(fx, "rev-parse", "HEAD") == before and read(fx, "k") == "k dirty\n", s.text())
    s.quit()

    fx = build(root, "stash")
    other = twin(fx, root, "stash_git")
    write(fx, "k", "k dirty\n")
    write(other, "k", "k dirty\n")
    git_rebase(other, "--autostash", "main")
    s = P.Session(binpath, fx)
    s.send("r")
    s.send("a")
    s.send("r")
    s.send("main")
    s.send("\r")
    check("autostash: r a then r r rebases and brings the dirty file back", read(fx, "k") == "k dirty\n" and out(fx, "status", "--short") == " M k" and out(fx, "stash", "list") == "", "%r %r" % (out(fx, "status", "--short"), out(fx, "stash", "list")))
    same(fx, other, "autostash: dirty tree")
    check("autostash: reflogs equal git's", reflog_of(fx, "feature") == reflog_of(other, "feature") and reflog_of(fx, "HEAD") == reflog_of(other, "HEAD"), "%r vs %r" % (reflog_of(fx, "HEAD"), reflog_of(other, "HEAD")))
    s.quit()

    # --- interop, both ways -----------------------------------------------------------------------------------------------
    fx = build(root, "interop_git_start")
    git(fx, "checkout", "-q", "conf")
    other = twin(fx, root, "interop_git_only")
    git_rebase(other, "main")
    git(other, "checkout", "--ours", "f")
    git(other, "add", "f")
    git_rebase(other, "--continue")
    git_rebase(fx, "main")
    s = P.Session(binpath, fx)
    t = s.text()
    check("interop: a rebase started by git shows the banner and the Unmerged section", "REBASING 2/3" in t and "UU  f" in t, t)
    cursor_to(s, "UU  f")
    s.send("\r")
    s.send("a")
    s.send("r")
    s.send("c")
    check("interop: resolving in the UI and r c finishes git's rebase", "rebase finished" in s.text() and not has(fx, "rebase-merge") and fsck_clean(fx), s.text())
    same(fx, other, "interop: git started, UI finished")
    s.quit()

    fx = build(root, "interop_ui_start")
    git(fx, "checkout", "-q", "conf")
    other = twin(fx, root, "interop_ui_only")
    git_rebase(other, "main")
    git(other, "checkout", "--ours", "f")
    git(other, "add", "f")
    git_rebase(other, "--continue")
    s = P.Session(binpath, fx)
    pick(s, "r", "main")
    cursor_to(s, "UU  f")
    s.send("\r")
    s.send("a")
    s.quit()
    r = git_rebase(fx, "--continue")
    check("interop: git rebase --continue finishes the rebase the UI started", r.returncode == 0 and not has(fx, "rebase-merge") and fsck_clean(fx), r.stdout + r.stderr)
    same(fx, other, "interop: UI started, git finished")
    check("interop: reflog lines equal git's", reflog_of(fx, "conf") == reflog_of(other, "conf"), "%r vs %r" % (reflog_of(fx, "conf"), reflog_of(other, "conf")))

    # --- pull: rebase instead of merge --------------------------------------------------------------------------------------
    srvroot = os.path.join(root, "pullsrv")
    os.makedirs(srvroot)
    server = None
    try:
        bare = os.path.join(srvroot, "srv", "repo.git")
        os.makedirs(bare)
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", bare], check=True)
        subprocess.run(["git", "-C", bare, "config", "http.receivepack", "true"], check=True)
        seed = P.make_fixture(srvroot, "seed")
        write(seed, "a", "a\n")
        write(seed, "b", "b\n")
        commit_all(seed, "base")
        git(seed, "push", "-q", bare, "main")
        server = M.start_server(srvroot)
        if server is None:
            print("note pull rebase: skipped, no git-http-backend or the server did not start")
        else:
            url = server[1]
            cl = os.path.join(srvroot, "client")
            subprocess.run(["git", "clone", "-q", url, cl], check=True, capture_output=True)
            write(seed, "a", "a upstream\n")
            commit_all(seed, "upstream")
            git(seed, "push", "-q", bare, "main")
            write(cl, "b", "b local\n")
            commit_all(cl, "local")
            ask = twin(cl, srvroot, "client_ask")
            cfg = twin(cl, srvroot, "client_cfg")
            upstream_tip = out(seed, "rev-parse", "HEAD")
            oracle = twin(cl, srvroot, "client_git")
            git(oracle, "fetch", "-q", "origin")
            git_rebase(oracle, "origin/main")

            s = P.Session(binpath, cl)
            s.send("F")
            s.send("p")
            time.sleep(1.5)
            s.drain(1.0)
            t = s.text()
            check("pull: a diverged branch offers merge or rebase", "origin/main has diverged" in t and "merge it?" in t and "rebase" in t, t)
            s.send("r")
            time.sleep(0.5)
            s.drain(0.5)
            parents = out(cl, "rev-list", "--parents", "-n1", "HEAD").split()
            check("pull: r rebases onto the fetched tip (a linear history on top of origin/main)", len(parents) == 2 and parents[1:] == [out(cl, "rev-parse", "HEAD~1")] and out(cl, "rev-parse", "HEAD~1") == upstream_tip, "%r" % parents)
            same(cl, oracle, "pull: rebase after the fetch")
            check("pull: clean, fsck clean", out(cl, "status", "--short") == "" and fsck_clean(cl))
            s.quit()

            subprocess.run(["git", "-C", cfg, "config", "pull.rebase", "true"], check=True)
            s = P.Session(binpath, cfg)
            s.send("F")
            s.send("p")
            time.sleep(1.5)
            s.drain(1.5)
            t = s.text()
            check("pull: pull.rebase=true rebases without asking", "merge it?" not in t and out(cfg, "rev-parse", "HEAD~1") == upstream_tip and len(out(cfg, "rev-list", "--parents", "-n1", "HEAD").split()) == 2, t)
            same(cfg, oracle, "pull: pull.rebase=true")
            s.quit()

            s = P.Session(binpath, ask)
            s.send("F")
            s.send("p")
            time.sleep(1.5)
            s.drain(1.0)
            s.send("y")
            ps = out(ask, "rev-list", "--parents", "-n1", "HEAD").split()
            check("pull: y still merges (two parents)", len(ps) == 3, "%r" % ps)
            s.quit()
    finally:
        if server is not None:
            server[0].kill()

    print("pty_rebase: %d checks passed, %d failed" % (passed, failures))
    return failures


if __name__ == "__main__":
    sys.exit(1 if main() > 0 else 0)
