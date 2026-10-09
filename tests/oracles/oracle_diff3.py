#!/usr/bin/env python3
"""Compare t_diff3's output with `git merge-file -p` on generated cases.

    oracle_diff3.py DIR COUNT

For every DIR/NNNNN.{base,ours,theirs} (see gen_merge_cases.py), after t_diff3
has written NNNNN.m / .m3 / .n / .rt next to them: run real git and require
the same bytes, the same conflict count (merge-file's exit status, capped at
127), and a clean .rt (the conflict reader's own checks).  Prints
`N cases, F failed` and the first few differences; exit status 1 if any.
This is the only place git is run, on files in a disposable directory.
"""
import os
import subprocess
import sys

GIT_ENV = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", LC_ALL="C")


def merge_file(stem, diff3):
    cmd = ["git", "merge-file", "-p", "-L", "ours", "-L", "base", "-L", "theirs"]
    if diff3:
        cmd.append("--diff3")
    cmd += [stem + ".ours", stem + ".base", stem + ".theirs"]
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=GIT_ENV)
    return r.stdout, r.returncode


def main():
    d, count = sys.argv[1], int(sys.argv[2])
    failed = 0
    shown = 0
    conflicted = 0
    for c in range(count):
        stem = os.path.join(d, "%05d" % c)
        got = open(stem + ".m", "rb").read()
        got3 = open(stem + ".m3", "rb").read()
        counts = [int(x) for x in open(stem + ".n").read().split()]
        rt = open(stem + ".rt").read()
        want, rc = merge_file(stem, False)
        want3, rc3 = merge_file(stem, True)
        problems = []
        if got != want:
            problems.append("merge-file output differs")
        if got3 != want3:
            problems.append("merge-file --diff3 output differs")
        if min(counts[0], 127) != rc:
            problems.append("conflict count %d, git %d" % (counts[0], rc))
        if min(counts[1], 127) != rc3:
            problems.append("diff3 conflict count %d, git %d" % (counts[1], rc3))
        if rt != "ok":
            problems.append("reader: " + rt)
        if rc:
            conflicted += 1
        if problems:
            failed += 1
            if shown < 5:
                shown += 1
                print("FAIL case %s: %s" % (stem, "; ".join(problems)))
    print("%d cases, %d with conflicts, %d failed" % (count, conflicted, failed))
    sys.exit(1 if failed else 0)


main()
