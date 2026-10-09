#!/usr/bin/env python3
"""Compare t_diff3's Level.Zealous output (NNNNN.mz) with a real `git merge`.

    oracle_zealous.py DIR COUNT SCRATCH

`git merge-file` runs the merge at the level that also joins conflicts with
no letter or digit between them, `git merge` one below it; a real merge in a
disposable repository under SCRATCH is how the second is checked.  The merge is
`-s recursive`: it diffs with Myers like merge-file does, where the default
strategy (ort) diffs with histogram.
Per case: init, commit base on `main`, branch `theirs` with theirs' file,
`main` with ours', `git merge theirs`; the file left in the work tree (conflict
markers and all) is compared with .mz after its `HEAD` marker label is renamed
`ours`, which is what t_diff3 passes. Fixed identities and dates throughout,
and `git fsck --strict` on every repository.
"""
import os
import shutil
import subprocess
import sys

ENV = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", LC_ALL="C",
           GIT_AUTHOR_NAME="T", GIT_AUTHOR_EMAIL="t@example.com", GIT_AUTHOR_DATE="2020-01-01T00:00:00Z",
           GIT_COMMITTER_NAME="T", GIT_COMMITTER_EMAIL="t@example.com", GIT_COMMITTER_DATE="2020-01-01T00:00:00Z")


def git(repo, *args, check=True):
    r = subprocess.run(["git", "-C", repo] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=ENV)
    if check and r.returncode != 0:
        raise SystemExit("git %s failed: %s" % (" ".join(args), r.stderr.decode()))
    return r


def put(repo, data):
    with open(os.path.join(repo, "f"), "wb") as f:
        f.write(data)
    git(repo, "add", "f")
    git(repo, "commit", "-q", "--allow-empty", "-m", "c")


def main():
    d, count, scratch = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    failed = 0
    for c in range(count):
        stem = os.path.join(d, "%05d" % c)
        base, ours, theirs = (open("%s.%s" % (stem, n), "rb").read() for n in ("base", "ours", "theirs"))
        repo = os.path.join(scratch, "r%05d" % c)
        shutil.rmtree(repo, ignore_errors=True)
        os.makedirs(repo)
        git(repo, "init", "-q", "-b", "main")
        git(repo, "config", "core.autocrlf", "false")
        put(repo, base)
        git(repo, "checkout", "-q", "-b", "theirs")
        put(repo, theirs)
        git(repo, "checkout", "-q", "main")
        put(repo, ours)
        git(repo, "merge", "-q", "--no-edit", "-s", "recursive", "theirs", check=False)
        got = open(os.path.join(repo, "f"), "rb").read()
        got = got.replace(b"<<<<<<< HEAD", b"<<<<<<< ours")
        want = open(stem + ".mz", "rb").read()
        git(repo, "fsck", "--strict")
        if got != want:
            failed += 1
            if failed <= 5:
                print("FAIL case %s" % stem)
        shutil.rmtree(repo, ignore_errors=True)
    print("%d cases, %d failed" % (count, failed))
    sys.exit(1 if failed else 0)


main()
