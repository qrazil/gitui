#!/usr/bin/env python3
"""Line-level staging against real `git apply`.

    oracle_lines.py prepare DIR COUNT SEED     DIR/NNNNN.{base,ours} -> .old .new .sel
    oracle_lines.py prepare-named DIR           hand-written cases; prints their count
    oracle_lines.py check   DIR COUNT SCRATCH  compare t_lines' .applied/.reverted

`prepare` takes the generated files (gen_merge_cases.py) as old = base and new =
ours, runs `git diff --no-index --no-indent-heuristic -U1000000` to learn the
edit script (the same one GIT_xdiff makes: tests/test_xdiff.sh), and picks a
selection of its changed lines -- all, none, only the removals, only the
additions, a single line, a contiguous run, or a random subset -- written
as op indices to .sel.

`check` builds, for each case, the patch that holds exactly the selection:

    stage  (apply to old):  selected `-`/`+` kept; an unselected `-` becomes
                            context; an unselected `+` is left out
    unstage (apply -R to new): selected `-`/`+` kept; an unselected `+` becomes
                            context; an unselected `-` is left out

and applies it in a disposable repository, `git apply --cached` on a blob of
old, `git apply --cached -R` on a blob of new, comparing the resulting index
blob with .applied / .reverted. The listing t_lines wrote (.ops) must also
equal git's own, so that "op 3" means the same line to both. With nothing
selected there is no patch to apply and the answer must be the file unchanged.
Prints `N cases, F failed` and, with git's result absent for a class of
selection, how many were skipped and why.
"""
import os
import random
import shutil
import subprocess
import sys

ENV = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", LC_ALL="C",
           GIT_AUTHOR_NAME="T", GIT_AUTHOR_EMAIL="t@example.com", GIT_AUTHOR_DATE="2020-01-01T00:00:00Z",
           GIT_COMMITTER_NAME="T", GIT_COMMITTER_EMAIL="t@example.com", GIT_COMMITTER_DATE="2020-01-01T00:00:00Z")


def run(args, cwd=None, data=None):
    return subprocess.run(args, cwd=cwd, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=ENV)


def git_ops(old, new):
    """git's edit script for old -> new: [(kind, line bytes incl. newline or not)]."""
    r = run(["git", "diff", "--no-index", "--no-indent-heuristic", "-U1000000", old, new])
    out = r.stdout
    i = out.find(b"\n@@ ")
    if i < 0:  # identical files: git prints nothing, every line is context
        text = open(old, "rb").read()
        return [(b" ", l) for l in text.splitlines(keepends=True)]
    body = out[out.index(b"\n", i + 1) + 1:]
    ops = []
    for raw in body.split(b"\n")[:-1] if body.endswith(b"\n") else body.split(b"\n"):
        if raw.startswith(b"\\"):
            kind, line = ops[-1]
            ops[-1] = (kind, line[:-1])  # the last line had no newline
        else:
            ops.append((raw[:1], raw[1:] + b"\n"))
    return ops


def prepare(d, count, seed):
    rng = random.Random(seed)
    for c in range(count):
        stem = os.path.join(d, "%05d" % c)
        old = open(stem + ".base", "rb").read()
        new = open(stem + ".ours", "rb").read()
        open(stem + ".old", "wb").write(old)
        open(stem + ".new", "wb").write(new)
        ops = git_ops(stem + ".old", stem + ".new")
        changed = [i for i, (k, _) in enumerate(ops) if k != b" "]
        adds = [i for i in changed if ops[i][0] == b"+"]
        rems = [i for i in changed if ops[i][0] == b"-"]
        mode = rng.choice(["all", "none", "removals", "additions", "one", "run", "subset", "subset", "subset", "half"])
        if mode == "all":
            sel = changed
        elif mode == "none":
            sel = []
        elif mode == "removals":
            sel = rems
        elif mode == "additions":
            sel = adds
        elif mode == "one":
            sel = [rng.choice(changed)] if changed else []
        elif mode == "run":
            if changed:
                a = rng.randrange(len(changed))
                sel = changed[a:a + rng.randint(1, 5)]
            else:
                sel = []
        elif mode == "half":
            sel = [i for i in changed if rng.random() < 0.5]
        else:
            p = rng.random()
            sel = [i for i in changed if rng.random() < p]
        open(stem + ".sel", "w").write(" ".join(str(i) for i in sel))


def pick(ops, kinds=b"+-", only=None):
    """Indices of changed ops of the given kinds, optionally only the nth..."""
    got = [i for i, (k, _) in enumerate(ops) if k in kinds]
    return got if only is None else [got[i] for i in only if i < len(got)]


# name, old, new, selection (function of the ops), the expected result of staging
# it (None: only git is asked), that of reverting it
NAMED = [
    ("delete-only-all", b"a\nb\nc\nd\n", b"a\nd\n", lambda o: pick(o), b"a\nd\n", b"a\nb\nc\nd\n"),
    ("delete-only-one", b"a\nb\nc\nd\n", b"a\nd\n", lambda o: pick(o, only=[1]), b"a\nb\nd\n", b"a\nc\nd\n"),
    ("add-only-all", b"a\nd\n", b"a\nb\nc\nd\n", lambda o: pick(o), b"a\nb\nc\nd\n", b"a\nd\n"),
    ("add-only-one", b"a\nd\n", b"a\nb\nc\nd\n", lambda o: pick(o, only=[0]), b"a\nb\nd\n", b"a\nc\nd\n"),
    ("mixed-all", b"a\nb\nc\n", b"a\nB\nc\nd\n", lambda o: pick(o), b"a\nB\nc\nd\n", b"a\nb\nc\n"),
    ("mixed-removal-only", b"a\nb\nc\n", b"a\nB\nc\nd\n", lambda o: pick(o, b"-"), b"a\nc\n", b"a\nb\nB\nc\nd\n"),
    ("mixed-addition-only", b"a\nb\nc\n", b"a\nB\nc\nd\n", lambda o: pick(o, b"+"), b"a\nb\nB\nc\nd\n", b"a\nc\n"),
    ("mixed-pair-of-two", b"a\nb\nc\nd\ne\n", b"a\nB\nc\nD\ne\n", lambda o: pick(o, only=[0, 1]), b"a\nB\nc\nd\ne\n", b"a\nb\nc\nD\ne\n"),
    ("empty-selection", b"a\nb\n", b"a\nc\n", lambda o: [], b"a\nb\n", b"a\nc\n"),
    ("no-change", b"a\nb\n", b"a\nb\n", lambda o: [0, 1], b"a\nb\n", b"a\nb\n"),
    ("file-addition-all", b"", b"a\nb\n", lambda o: pick(o), b"a\nb\n", b""),
    ("file-addition-one-line", b"", b"a\nb\nc\n", lambda o: pick(o, only=[1]), b"b\n", b"a\nc\n"),
    ("file-addition-none", b"", b"a\nb\n", lambda o: [], b"", b"a\nb\n"),
    ("file-deletion-all", b"a\nb\n", b"", lambda o: pick(o), b"", b"a\nb\n"),
    ("file-deletion-one-line", b"a\nb\nc\n", b"", lambda o: pick(o, only=[1]), b"a\nc\n", b"b\n"),
    ("file-deletion-none", b"a\nb\n", b"", lambda o: [], b"a\nb\n", b""),
    ("eof-both-without-newline", b"a\nb", b"a\nc", lambda o: pick(o), b"a\nc", b"a\nb"),
    ("eof-newline-added", b"a\nb", b"a\nb\n", lambda o: pick(o), b"a\nb\n", b"a\nb"),
    ("eof-newline-removed", b"a\nb\n", b"a\nb", lambda o: pick(o), b"a\nb", b"a\nb\n"),
    ("eof-newline-add-half", b"a\nb", b"a\nb\n", lambda o: pick(o, b"+"), b"a\nbb\n", b"a\n"),
    ("eof-newline-remove-half", b"a\nb\n", b"a\nb", lambda o: pick(o, b"-"), b"a\n", b"a\nb\nb"),
    ("eof-append-line-to-unterminated", b"a\nb", b"a\nb\nc", lambda o: pick(o), b"a\nb\nc", b"a\nb"),
    ("eof-append-only-the-new-line", b"a\nb", b"a\nb\nc", lambda o: pick(o, b"+", only=[1]), b"a\nbc", b"a\nb\n"),
    ("eof-unterminated-change-in-middle", b"a\nb\nc", b"a\nB\nc", lambda o: pick(o), b"a\nB\nc", b"a\nb\nc"),
    ("eof-delete-unterminated-last", b"a\nb\nc", b"a\nb\n", lambda o: pick(o), b"a\nb\n", b"a\nb\nc"),
    ("eof-file-addition-unterminated", b"", b"a\nb", lambda o: pick(o), b"a\nb", b""),
    ("eof-file-deletion-unterminated", b"a\nb", b"", lambda o: pick(o), b"", b"a\nb"),
    ("crlf-mixed", b"a\r\nb\r\nc\r\n", b"a\r\nB\nc\r\n", lambda o: pick(o, b"-"), b"a\r\nc\r\n", b"a\r\nb\r\nB\nc\r\n"),
    ("repeated-lines", b"x\nx\nx\nx\n", b"x\nx\n", lambda o: pick(o, only=[0]), b"x\nx\nx\n", b"x\nx\nx\n"),
]


def prepare_named(d):
    for n, (name, old, new, selector, want_applied, want_reverted) in enumerate(NAMED):
        stem = os.path.join(d, "%05d" % n)
        open(stem + ".old", "wb").write(old)
        open(stem + ".new", "wb").write(new)
        # `.stale`: a text the ops were not made from, which t_lines must refuse
        open(stem + ".name", "w").write(name)
        open(stem + ".want_applied", "wb").write(want_applied)
        open(stem + ".want_reverted", "wb").write(want_reverted)
        ops = git_ops(stem + ".old", stem + ".new")
        open(stem + ".sel", "w").write(" ".join(str(i) for i in selector(ops)))
        open(stem + ".stale", "wb").write(old + b"extra\n")
    return len(NAMED)


def listing(ops):
    out = b"%d\n" % len(ops)
    for kind, line in ops:
        out += kind + line + (b"" if line.endswith(b"\n") else b"\n")
    return out


def patch_for(ops, selected, staging):
    """The patch holding exactly `selected` (a set of op indices), None if it changes nothing."""
    body = b""
    n_old = n_new = 0
    changes = 0
    for i, (kind, line) in enumerate(ops):
        text = line if line.endswith(b"\n") else line + b"\n\\ No newline at end of file\n"
        if kind == b" ":
            body += b" " + text
            n_old += 1
            n_new += 1
        elif kind == b"-":
            if i in selected:
                body += b"-" + text
                n_old += 1
                changes += 1
            elif staging:
                body += b" " + text
                n_old += 1
                n_new += 1
        else:
            if i in selected:
                body += b"+" + text
                n_new += 1
                changes += 1
            elif not staging:
                body += b" " + text
                n_old += 1
                n_new += 1
    if not changes:
        return None
    head = b"--- a/f\n+++ b/f\n@@ -%d,%d +%d,%d @@\n" % (1 if n_old else 0, n_old, 1 if n_new else 0, n_new)
    return head + body


def apply_in_repo(repo, start_blob, patch, reverse):
    shutil.rmtree(repo, ignore_errors=True)
    os.makedirs(repo)
    run(["git", "init", "-q", "-b", "main"], cwd=repo)
    oid = run(["git", "hash-object", "-w", "--stdin"], cwd=repo, data=start_blob).stdout.strip().decode()
    run(["git", "update-index", "--add", "--cacheinfo", "100644,%s,f" % oid], cwd=repo)
    open(os.path.join(repo, "p.patch"), "wb").write(patch)
    cmd = ["git", "apply", "--cached", "--whitespace=nowarn", "--unidiff-zero"]
    if reverse:
        cmd.append("-R")
    r = run(cmd + ["p.patch"], cwd=repo)
    if r.returncode != 0:
        return None, r.stderr.decode()
    ls = run(["git", "ls-files", "-s"], cwd=repo).stdout
    if not ls.strip():
        got = b""  # git apply deletes the file when nothing is left
    else:
        got = run(["git", "cat-file", "blob", ":f"], cwd=repo).stdout
    fsck = run(["git", "fsck", "--strict"], cwd=repo)
    if fsck.returncode != 0:
        return None, "fsck: " + fsck.stderr.decode()
    return got, ""


def check(d, count, scratch):
    failed = 0
    applied_by_git = 0
    for c in range(count):
        stem = os.path.join(d, "%05d" % c)
        old = open(stem + ".old", "rb").read()
        new = open(stem + ".new", "rb").read()
        sel = set(int(x) for x in open(stem + ".sel").read().split())
        ops = git_ops(stem + ".old", stem + ".new")
        problems = []
        wants = {}
        for suffix in ("applied", "reverted"):
            if os.path.exists("%s.want_%s" % (stem, suffix)):
                wants[suffix] = open("%s.want_%s" % (stem, suffix), "rb").read()
        if os.path.exists(stem + ".stale"):
            for suffix in ("stale_applied", "stale_reverted"):
                if open("%s.%s" % (stem, suffix), "rb").read() != b"NONE":
                    problems.append("%s is not NONE" % suffix)
            if open(stem + ".far", "rb").read() != b"NONE":
                problems.append("an out-of-range index is not NONE")
        if open(stem + ".ops", "rb").read() != listing(ops):
            problems.append("op listing differs")
        for suffix, start, staging, reverse in (("applied", old, True, False), ("reverted", new, False, True)):
            got = open("%s.%s" % (stem, suffix), "rb").read()
            patch = patch_for(ops, sel, staging)
            if patch is None:
                want = start
            else:
                want, err = apply_in_repo(os.path.join(scratch, "r"), start, patch, reverse)
                if want is None:
                    problems.append("git apply refused the %s patch: %s" % (suffix, err.strip()))
                    continue
                applied_by_git += 1
            if got != want:
                problems.append("%s differs from git apply" % suffix)
            if suffix in wants and wants[suffix] != want:
                problems.append("%s: git gives %r, the case expects %r" % (suffix, want, wants[suffix]))
        if problems:
            failed += 1
            if failed <= 5:
                print("FAIL case %s: %s" % (stem, "; ".join(problems)))
    shutil.rmtree(os.path.join(scratch, "r"), ignore_errors=True)
    print("%d cases (%d git apply runs), %d failed" % (count, applied_by_git, failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    if sys.argv[1] == "prepare-named":
        print(prepare_named(sys.argv[2]))
    elif sys.argv[1] == "prepare":
        prepare(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
    else:
        check(sys.argv[2], int(sys.argv[3]), sys.argv[4])
