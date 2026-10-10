#!/usr/bin/env python3
"""The cherry-pick and revert UI of the compiled `ourgitui`, driven under a real
pty against disposable git fixtures this script builds and destroys itself. Real
`git` is the oracle both ways: what the UI leaves is compared with what git does
in a copy of the same fixture (trees, messages, authors, state files, reflog,
`fsck --strict`), and sequences that git started are finished in the UI.

    python3 tests/pty_sequencer.py <ourgitui-binary> <scratch-dir>

Every `ok` / `FAIL` line is one check; the exit status says whether any failed.
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pty_e2e as P  # noqa: E402  (main() there is guarded)

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


def git(fx, *args):
    return P.git(fx, *args, env=P.GIT_ENV)


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


BASE = "a\nb\nc\nd\ne\nf\ng\nh\n"


def build(root, name):
    """main: base, m1 (f line 3 = OURS, adds m). Branches off base: clean (c1),
    side (s1 adds g, s2 edits line 8, s3 edits line 3: conflicts with m1), dup
    (adds m as m1 does), mrg (a merge of mx into my)."""
    fx = P.make_fixture(root, name)
    git(fx, "config", "merge.renames", "false")
    write(fx, "f", BASE)
    write(fx, "k", "k\n")
    commit_all(fx, "base")
    git(fx, "tag", "t0")
    git(fx, "checkout", "-q", "-b", "clean")
    write(fx, "c", "c\n")
    commit_all(fx, "c1")
    git(fx, "checkout", "-q", "-b", "side", "t0")
    write(fx, "g", "g\n")
    commit_all(fx, "s1")
    write(fx, "f", "a\nb\nc\nd\ne\nf\ng\nH\n")
    commit_all(fx, "s2")
    write(fx, "f", "a\nb\nTHEIRS\nd\ne\nf\ng\nH\n")
    commit_all(fx, "s3")
    git(fx, "checkout", "-q", "-b", "dup", "t0")
    write(fx, "m", "m\n")
    commit_all(fx, "dup of m")
    git(fx, "checkout", "-q", "-b", "mx", "t0")
    write(fx, "x", "x\n")
    commit_all(fx, "x")
    git(fx, "checkout", "-q", "-b", "mrg", "t0")
    write(fx, "y", "y\n")
    commit_all(fx, "y")
    git(fx, "merge", "-q", "--no-ff", "-m", "merge x", "mx")
    git(fx, "checkout", "-q", "main")
    write(fx, "f", "a\nb\nOURS\nd\ne\nf\ng\nh\n")
    write(fx, "m", "m\n")
    commit_all(fx, "m1")
    return fx


def twin(fx, root, name):
    dest = os.path.join(root, name)
    P.copy_repo(fx, dest)
    return dest


def cursor_to(s, needle):
    """Select the outline row containing `needle`."""
    for _ in range(14):
        s.send("k")
    lines = s.text().split("\n")
    first = 2 if len(lines) > 1 and ("CHERRY-PICKING" in lines[1] or "REVERTING" in lines[1]) else 1
    for i, ln in enumerate(lines):
        if needle in ln and ln.startswith("│"):
            for _ in range(i - first):
                s.send("j")
            return True
    return False


def pick_branch(s, verb_key, key, branch):
    cursor_to(s, branch + "  ")
    s.send(verb_key)
    s.send(key)


def same_result(fx, other, what, fmt="%an|%ae|%s%n%b"):
    a = (out(fx, "rev-parse", "HEAD^{tree}"), out(fx, "log", "-1", "--format=" + fmt), out(fx, "status", "--short"))
    b = (out(other, "rev-parse", "HEAD^{tree}"), out(other, "log", "-1", "--format=" + fmt), out(other, "status", "--short"))
    check(what + ": tree, message and status equal git's", a == b, "%r vs %r" % (a, b))


def main():
    if len(sys.argv) != 3:
        print("usage: pty_sequencer.py <ourgitui-binary> <scratch-dir>", file=sys.stderr)
        return 2
    binpath = os.path.abspath(sys.argv[1])
    root = os.path.abspath(sys.argv[2])
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(root)

    # --- the menus ---------------------------------------------------------------
    fx = build(root, "menus")
    s = P.Session(binpath, fx)
    pick_branch(s, "A", "", "clean")
    t = s.text()
    check("menu: A on a branch row opens the cherry-pick menu for that branch", "cherry-pick clean" in t and "cherry-pick -x" in t and "-n: apply to the index" in t and "a merge commit against its first parent" in t, t)
    s.send("\x1b")
    check("menu: Escape closes it", "cherry-pick clean" not in s.text(), s.text())
    cursor_to(s, "m1")
    s.send("V")
    t = s.text()
    check("menu: V on a commit row opens the revert menu with no -x", "revert " in t and "revert -n" in t and "-x" not in t, t)
    s.send("\x1b")
    cursor_to(s, "Untracked")
    s.send("A")
    s.send("p")
    check("menu: p with no commit under the cursor says so and changes nothing", "put the cursor on a commit" in s.text() and out(fx, "rev-parse", "HEAD") == out(fx, "rev-parse", "main"), s.text())
    s.quit()

    # --- a clean pick, -x, -n ----------------------------------------------------
    fx = build(root, "clean")
    ref = twin(fx, root, "clean_git")
    git(ref, "cherry-pick", "clean")
    before = out(fx, "rev-parse", "HEAD")
    s = P.Session(binpath, fx)
    pick_branch(s, "A", "p", "clean")
    t = s.text()
    check("pick: p commits it and says so", "cherry-pick: committed" in t, t)
    same_result(fx, ref, "pick")
    check("pick: the parent is the old HEAD, the author is kept and the committer is the client's", out(fx, "rev-parse", "HEAD^") == before and out(fx, "log", "-1", "--format=%an|%cn") == "Fixture|Client", out(fx, "log", "-1", "--format=%P|%an|%cn"))
    rl = out(fx, "reflog", "-1", "--format=%gs")
    check("pick: the reflog says 'cherry-pick: c1', no state is left behind, fsck --strict is clean", rl == "cherry-pick: c1" and not has(fx, "CHERRY_PICK_HEAD") and not has(fx, "sequencer") and fsck_clean(fx), rl)
    s.send("@")
    check("pick: the command log records 'cherry-pick clean'", "cherry-pick clean" in s.text(), s.text())
    s.send("\x1b")
    s.quit()

    fx = build(root, "origin")
    ref = twin(fx, root, "origin_git")
    git(ref, "cherry-pick", "-x", "clean")
    s = P.Session(binpath, fx)
    pick_branch(s, "A", "x", "clean")
    same_result(fx, ref, "pick -x")
    check("pick -x: the message ends with the origin line", out(fx, "log", "-1", "--format=%b").endswith("(cherry picked from commit " + out(fx, "rev-parse", "clean") + ")"), out(fx, "log", "-1", "--format=%B"))
    s.quit()

    fx = build(root, "nocommit")
    ref = twin(fx, root, "nocommit_git")
    git(ref, "cherry-pick", "-n", "clean")
    before = out(fx, "rev-parse", "HEAD")
    s = P.Session(binpath, fx)
    pick_branch(s, "A", "n", "clean")
    check("pick -n: HEAD does not move; the index and files equal git's", out(fx, "rev-parse", "HEAD") == before and out(fx, "status", "--short") == out(ref, "status", "--short") == "A  c" and out(fx, "write-tree") == out(ref, "write-tree"), out(fx, "status", "--short"))
    check("pick -n: no CHERRY-PICKING banner, as git leaves no CHERRY_PICK_HEAD", "CHERRY-PICKING" not in s.text() and not has(fx, "CHERRY_PICK_HEAD"), s.text())
    s.quit()

    # --- a conflict: banner, blocked operations, resolution, continue -----------------
    fx = build(root, "conf")
    ref = twin(fx, root, "conf_git")
    git(ref, "cherry-pick", "side")
    write(ref, "f", "a\nb\nTHEIRS\nd\ne\nf\ng\nh\n")
    git(ref, "add", "f")
    git(ref, "-c", "core.editor=true", "cherry-pick", "--continue")
    abort_fx = twin(fx, root, "conf_abort")
    before = out(fx, "rev-parse", "HEAD")
    s = P.Session(binpath, fx)
    pick_branch(s, "A", "p", "side")
    t = s.text()
    check("conflict: the outline shows the CHERRY-PICKING banner and the Unmerged paths section", "CHERRY-PICKING (1 conflict)" in t and "Unmerged paths (1)" in t and "UU  f" in t, t)
    check("conflict: the status line says where it stopped", "stopped on" in t and "conflict" in t, t)
    check(
        "conflict: git agrees (UU f, three stages, CHERRY_PICK_HEAD, MERGE_MSG with its Conflicts block, no sequencer dir)",
        out(fx, "status", "--short") == "UU f" and len(out(fx, "ls-files", "-u").split("\n")) == 3 and has(fx, "CHERRY_PICK_HEAD") and "# Conflicts:" in read(fx, ".git/MERGE_MSG") and not has(fx, "sequencer"),
        out(fx, "status", "--short"),
    )
    check("conflict: the file holds the markers git would write", "<<<<<<< HEAD\nOURS\n=======\nTHEIRS\n>>>>>>> " in read(fx, "f"), read(fx, "f"))
    s.send("g")
    check("conflict: the banner is still there after a refresh", "CHERRY-PICKING" in s.text(), s.text())
    for key, word in (("c", "commit"), ("b", "branch"), ("m", "merge"), ("F", "pull"), ("Z", "undo")):
        s.send(key)
        t = s.text()
        check("blocked: %s is refused while CHERRY-PICKING" % key, word + " is blocked while CHERRY-PICKING" in t, t)
        if "blocked" not in t:
            s.send("\x1b")
    check("blocked: nothing moved", out(fx, "rev-parse", "HEAD") == before, "")
    cursor_to(s, "UU  f")
    s.send("\r")
    t = s.text()
    check("resolve: Enter on the unmerged path opens the same resolution view the merge uses", "resolve f" in t and "(conflict 1 of 1)" in t, t)
    s.send("b")
    t = s.text()
    check("resolve: b takes theirs, stages the file and the banner says no conflicts left", "resolve f" not in t and "CHERRY-PICKING (no conflicts left: A c continues)" in t and out(fx, "status", "--short") == "M  f", t)
    s.send("A")
    t = s.text()
    check("continue: A while one is under way opens the continue/skip/abort menu", "continue: commit the resolved step" in t and "abort: put HEAD" in t and "cherry-pick forgotten" not in t, t)
    s.send("c")
    t = s.text()
    check("continue: c commits the step and the banner goes", "cherry-pick: committed" in t and "CHERRY-PICKING" not in t, t)
    same_result(fx, ref, "continue")
    check("continue: the step files are gone, the reflog says 'commit (cherry-pick): s3', fsck --strict is clean", not has(fx, "CHERRY_PICK_HEAD") and not has(fx, "AUTO_MERGE") and not has(fx, "MERGE_MSG") and out(fx, "reflog", "-1", "--format=%gs") == "commit (cherry-pick): s3" and fsck_clean(fx), out(fx, "reflog", "-1", "--format=%gs"))
    s.quit()

    # --- abort ----------------------------------------------------------------------
    s = P.Session(binpath, abort_fx)
    before = out(abort_fx, "rev-parse", "HEAD")
    pick_branch(s, "A", "p", "side")
    s.send("A")
    s.send("a")
    check("abort: a asks first", "put everything back?" in s.text(), s.text())
    s.send("x")
    check("abort: any other key keeps the sequence", "abort cancelled" in s.text() and has(abort_fx, "CHERRY_PICK_HEAD"), s.text())
    s.send("A")
    s.send("a")
    s.send("y")
    t = s.text()
    check(
        "abort: y puts HEAD, index and files back; the banner goes; the reflog says 'reset: moving to'",
        out(abort_fx, "rev-parse", "HEAD") == before and out(abort_fx, "status", "--short") == "" and not has(abort_fx, "CHERRY_PICK_HEAD") and "CHERRY-PICKING" not in t and out(abort_fx, "reflog", "-1", "--format=%gs").startswith("reset: moving to"),
        out(abort_fx, "reflog", "-1", "--format=%gs"),
    )
    check("abort: the file is back to main's", read(abort_fx, "f") == "a\nb\nOURS\nd\ne\nf\ng\nh\n", read(abort_fx, "f"))
    s.quit()

    # --- a range: stops, skip, finishes ----------------------------------------------
    fx = build(root, "range")
    ref = twin(fx, root, "range_git")
    git(ref, "cherry-pick", "t0..side")
    todo_ref = read(ref, ".git/sequencer/todo")
    git(ref, "cherry-pick", "--skip")
    s = P.Session(binpath, fx)
    s.send("A")
    s.send("r")
    check("range: r asks for it on the bottom row", "cherry-pick (A..B" in s.text(), s.text())
    s.send("t0..side")
    s.send("\r")
    t = s.text()
    check("range: it stops on the third commit's conflict with the banner", "CHERRY-PICKING (1 conflict)" in t and "stopped on" in t, t)
    check("range: .git/sequencer/todo is git's (pick <abbrev> <subject>)", read(fx, ".git/sequencer/todo") == todo_ref, "%r vs %r" % (read(fx, ".git/sequencer/todo"), todo_ref))
    check("range: HEAD has the two clean picks on top of main", out(fx, "log", "--format=%s", "-3") == "s2\ns1\nm1", out(fx, "log", "--format=%s", "-3"))
    s.send("A")
    s.send("s")
    t = s.text()
    check("skip: s drops the stopped step and finishes; the banner and sequencer dir go", "CHERRY-PICKING" not in t and not has(fx, "sequencer") and not has(fx, "CHERRY_PICK_HEAD"), t)
    check("skip: equals git's cherry-pick --skip (tree, subjects, status), fsck --strict is clean", out(fx, "rev-parse", "HEAD^{tree}") == out(ref, "rev-parse", "HEAD^{tree}") and out(fx, "log", "--format=%s", "-3") == out(ref, "log", "--format=%s", "-3") and out(fx, "status", "--short") == "" and fsck_clean(fx), out(fx, "log", "--format=%s", "-3"))
    s.quit()

    # --- a redundant pick stops as empty; skip ------------------------------------------
    fx = build(root, "empty")
    before = out(fx, "rev-parse", "HEAD")
    s = P.Session(binpath, fx)
    pick_branch(s, "A", "p", "dup")
    t = s.text()
    check("empty: a pick that changes nothing stops and says s skips it", "nothing is left to commit" in t and "A s skips it" in t and out(fx, "rev-parse", "HEAD") == before and has(fx, "CHERRY_PICK_HEAD"), t)
    s.send("A")
    s.send("s")
    check("empty: skip ends it, HEAD unmoved", not has(fx, "CHERRY_PICK_HEAD") and out(fx, "rev-parse", "HEAD") == before and "CHERRY-PICKING" not in s.text(), s.text())
    pick_branch(s, "A", "k", "dup")
    check("empty: k (keep redundant) commits it as an empty commit", out(fx, "rev-parse", "HEAD^") == before and out(fx, "log", "-1", "--format=%s") == "dup of m", s.text())
    s.quit()

    # --- a merge commit needs a parent --------------------------------------------------
    fx = build(root, "mergecommit")
    ref = twin(fx, root, "mergecommit_git")
    git(ref, "cherry-pick", "-m", "1", "mrg")
    before = out(fx, "rev-parse", "HEAD")
    s = P.Session(binpath, fx)
    pick_branch(s, "A", "p", "mrg")
    t = s.text()
    check("merge commit: p without a parent is refused with git's reason and writes nothing", "is a merge but no mainline parent was giv" in t and out(fx, "rev-parse", "HEAD") == before and not has(fx, "CHERRY_PICK_HEAD"), t)
    pick_branch(s, "A", "1", "mrg")
    same_result(fx, ref, "merge commit -m 1")
    s.quit()

    # --- revert from a commit row ---------------------------------------------------------
    fx = build(root, "revert")
    write(fx, "n", "n\n")
    commit_all(fx, "m2")
    ref = twin(fx, root, "revert_git")
    git(ref, "revert", "--no-edit", "HEAD")
    keep = twin(fx, root, "revert_n")
    s = P.Session(binpath, fx)
    cursor_to(s, "m2")
    s.send("V")
    s.send("p")
    t = s.text()
    check("revert: p on a commit row commits a revert of it", "revert: committed" in t, t)
    same_result(fx, ref, "revert", "%s%n%b")
    check("revert: the subject is Revert \"m2\", the reflog says 'revert: ...', fsck --strict is clean", out(fx, "log", "-1", "--format=%s") == 'Revert "m2"' and out(fx, "reflog", "-1", "--format=%gs").startswith("revert:") and fsck_clean(fx), out(fx, "log", "-1", "--format=%s"))
    s.quit()

    ref = twin(keep, root, "revert_n_git")
    git(ref, "revert", "-n", "HEAD")
    before = out(keep, "rev-parse", "HEAD")
    s = P.Session(binpath, keep)
    cursor_to(s, "m2")
    s.send("V")
    s.send("n")
    t = s.text()
    check("revert -n: HEAD stays, the revert is staged as in git, REVERT_HEAD is written and the banner says REVERTING", out(keep, "rev-parse", "HEAD") == before and out(keep, "write-tree") == out(ref, "write-tree") and has(keep, "REVERT_HEAD") and "REVERTING (no conflicts left: V c continues)" in t, t)
    s.send("V")
    s.send("q")
    check("quit: q forgets the sequence and keeps the staged revert", not has(keep, "REVERT_HEAD") and "REVERTING" not in s.text() and out(keep, "write-tree") == out(ref, "write-tree"), s.text())
    s.quit()

    # --- a sequence git started, finished here ---------------------------------------------
    fx = build(root, "interop")
    ref = twin(fx, root, "interop_git")
    for repo in (fx, ref):
        git(repo, "cherry-pick", "t0..side")
        git(repo, "checkout", "--theirs", "f")
        git(repo, "add", "f")
    git(ref, "-c", "core.editor=true", "cherry-pick", "--continue")
    s = P.Session(binpath, fx)
    t = s.text()
    check("interop: a conflicted sequence git started shows the banner on startup", "CHERRY-PICKING (no conflicts left: A c continues)" in t, t)
    s.send("A")
    s.send("c")
    check("interop: A c finishes it; the result is git's own", not has(fx, "sequencer") and not has(fx, "CHERRY_PICK_HEAD") and out(fx, "rev-parse", "HEAD^{tree}") == out(ref, "rev-parse", "HEAD^{tree}") and out(fx, "log", "--format=%s", "-4") == out(ref, "log", "--format=%s", "-4") and fsck_clean(fx), out(fx, "log", "--format=%s", "-4"))
    s.quit()

    # --- the other direction: started here, aborted by git -------------------------------------
    fx = build(root, "interop2")
    before = out(fx, "rev-parse", "HEAD")
    s = P.Session(binpath, fx)
    s.send("A")
    s.send("r")
    s.send("t0..side")
    s.send("\r")
    s.quit()
    # fs.stat has no ino/uid, so entries written here need one refresh before git's --abort
    git(fx, "update-index", "--refresh")
    o, e, rc = git(fx, "cherry-pick", "--abort")
    check("interop: git cherry-pick --abort undoes a sequence started here", rc == 0 and out(fx, "rev-parse", "HEAD") == before and out(fx, "status", "--short") == "" and not has(fx, "sequencer"), o + e)

    print("pty_sequencer: %d checks passed, %d failed" % (passed, failures))
    return failures


if __name__ == "__main__":
    sys.exit(1 if main() > 0 else 0)
