#!/usr/bin/env python3
"""What real git says about each revision expression in a file.

    revparse_oracle.py <work tree> <mode> <exprfile>

Per line of <exprfile> (taken exactly) one output line: `ok <names, space
separated>` or `err`. Modes:

    lines    git rev-parse <expr> --      (the trailing `--` is dropped)
    object   git rev-parse --verify <expr>
    walk     git rev-list <expr> --       (the commits, in git's order)

Only success or failure and the names are compared; git's messages are not.
"""
import subprocess
import sys

repo, mode, path = sys.argv[1:4]
with open(path, encoding="utf-8", newline="") as handle:
    body = handle.read()
exprs = body.split("\n")
if exprs and exprs[-1] == "":
    exprs.pop()

for expr in exprs:
    if mode == "lines":
        cmd = ["git", "-C", repo, "rev-parse", expr, "--"]
    elif mode == "object":
        cmd = ["git", "-C", repo, "rev-parse", "--verify", "-q", expr]
    else:
        cmd = ["git", "-C", repo, "rev-list", expr, "--"]
    done = subprocess.run(cmd, capture_output=True, timeout=60)
    if done.returncode != 0:
        print("err")
        continue
    out = done.stdout.decode().split("\n")
    if out and out[-1] == "":
        out.pop()
    if mode == "lines" and out and out[-1] == "--":
        out.pop()
    print("ok " + " ".join(out))
