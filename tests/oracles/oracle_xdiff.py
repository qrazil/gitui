#!/usr/bin/env python3
"""Compare t_xdiff's scripts with `git diff --no-index --no-indent-heuristic`.

    oracle_xdiff.py DIR COUNT

For every DIR/NNNNN.{base,ours,theirs} (see gen_merge_cases.py), after t_xdiff
has written NNNNN.dbo / .dbt / .dot: diff the same pair with real git, with
the whole file as one hunk (-U1000000), keep the hunk body and require the same
bytes.  git is only run on files in a disposable directory.
"""
import os
import subprocess
import sys

GIT_ENV = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", LC_ALL="C")


def git_script(a, b):
    r = subprocess.run(["git", "diff", "--no-index", "--no-indent-heuristic", "-U1000000", a, b],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=GIT_ENV)
    out = r.stdout
    i = out.find(b"\n@@ ")
    if i < 0:
        return b""
    return out[out.index(b"\n", i + 1) + 1:]


def main():
    d, count = sys.argv[1], int(sys.argv[2])
    failed = 0
    for c in range(count):
        stem = os.path.join(d, "%05d" % c)
        for suffix, a, b in (("dbo", "base", "ours"), ("dbt", "base", "theirs"), ("dot", "ours", "theirs")):
            got = open("%s.%s" % (stem, suffix), "rb").read()
            want = git_script("%s.%s" % (stem, a), "%s.%s" % (stem, b))
            if got != want:
                failed += 1
                if failed <= 5:
                    print("FAIL %s %s -> %s" % (stem, a, b))
    print("%d diffs, %d failed" % (3 * count, failed))
    sys.exit(1 if failed else 0)


main()
