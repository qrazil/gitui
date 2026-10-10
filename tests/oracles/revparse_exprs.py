#!/usr/bin/env python3
"""A deterministic pile of revision expressions for the fixture repository.

    revparse_exprs.py <work tree> <seed> <count> [<kind>]

One expression per line. <kind> is `all` (default), `plain` (no ranges, no
`:` forms: what `commit_id` and friends take) or `range`.

The names come from the repository itself, so the same script serves the
SHA-1 and SHA-256 fixtures. Abbreviations of every length from 4 up are drawn
from every kind of object, upper case included, so collisions between kinds
(and the type filter that breaks them) turn up.
"""
import random
import subprocess
import sys

repo, seed, count = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
kind = sys.argv[4] if len(sys.argv) > 4 else "all"
rng = random.Random(seed)


def git(*args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True).stdout


objects = git("cat-file", "--batch-all-objects", "--batch-check").split("\n")
ids = [line.split(" ")[0] for line in objects if line]
commits = git("rev-list", "--all").split()
tags = [line.split(" ")[0] for line in objects if line and line.split(" ")[1] == "tag"]
full = len(ids[0]) if ids else 40

names = [
    "HEAD", "@", "master", "feature", "side", "synth", "ca", "cb", "conf1", "conf2",
    "o1", "o2", "v1", "light", "v1v", "first", "late", "treetag", "blobtag", "ambig",
    "origin", "origin/master", "origin/feature", "origin/HEAD", "second/master",
    "refs/heads/master", "heads/master", "tags/v1", "refs/tags/v1", "remotes/origin/master",
    "refs/stash", "stash", "ORIG_HEAD", "FETCH_HEAD", "MERGE_HEAD", "CHERRY_PICK_HEAD",
    "looseraw", "junkfile", "refs/remotes/origin", "a1tip", "b1tip", "base-cc",
    "nosuch", "refs/heads/nosuch", "tiea", "tieb", "tiec", "HEAD@", "master@", "v1.", ".master", "ma..ster",
]
for line in git("for-each-ref", "--format=%(refname)").split():
    names.append(line)
    names.append(line.split("/", 2)[-1] if line.count("/") >= 2 else line)
head_names = ["HEAD", "master", "feature", "ca", "cb", "synth", "v1", "light", "@", "origin/master"]


def abbrev(oid):
    n = rng.choice([4, 4, 5, 6, 7, 8, 10, 12, 20, full - 1, full, full, 3, full + 1])
    text = oid[:n]
    if rng.random() < 0.15:
        text = text.upper()
    return text


def atom():
    pick = rng.random()
    if pick < 0.45:
        return rng.choice(names)
    if pick < 0.75 and ids:
        return abbrev(rng.choice(ids))
    if pick < 0.85 and commits:
        return abbrev(rng.choice(commits))
    if pick < 0.90 and tags:
        return abbrev(rng.choice(tags))
    if pick < 0.95 and commits:
        return rng.choice(["v1", "light", "first", "xx", "v1.0"]) + "-" + str(rng.randrange(0, 12)) + "-g" + abbrev(rng.choice(commits))
    return rng.choice(["HEAD", "master", "feature", "ca", "cb", "side"])


nums = ["", "0", "1", "2", "3", "4", "10", "99"]
# no empty alternatives: POSIX regcomp on macOS rejects them, glibc accepts them
patterns = ["c2", "second", "merge", "c[0-9]", "^c", "^m", "x$", "wip", "WIP", "body", "more text",
            "f[12]", "conf", "left", "o[12]", "octopus", "a1", "b1", "base", "inner", "nothing-like-this",
            "c.*5", "c5|c6", "(c|s)[1-9]", "c{1}", "c{1,2}", "c{2,}", "[[:digit:]]$", "[[:upper:]]", "a+", "c?3",
            ".", "", "*c", "c*", "^$", "e$", "[a-c][0-9]", "[^a-z ][0-9]", "c4.", "s1", "index on", "tie",
            "(c)", "()", "(c|s)c", "c|s|1", "c|[0-9]", "c\\.", "c\\(", "[]c]", "[^]c]", "[a-]", "[[:alpha:]-]",
            "c{", "c{x}", "(c", "c)", "c**", "c+?", "\\d", "\\bc", "[c-a]", "[[:foo:]]", "^c.$", "\\n"]
suffixes = [
    lambda: "^" + rng.choice(nums),
    lambda: "~" + rng.choice(nums),
    lambda: "^{" + rng.choice(["commit", "tree", "blob", "tag", "", "object", "foo"]) + "}",
    lambda: "^{/" + rng.choice(patterns) + "}",
    lambda: "^{/!-" + rng.choice(patterns) + "}",
    lambda: "^{/!!" + rng.choice(patterns) + "}",
    lambda: "^{/!" + rng.choice(patterns) + "}",
]
paths = ["a.txt", "dir", "dir/", "dir/b.txt", "dir/sub", "dir/sub/c.txt", "sp ace.txt", "empty", "gl",
         "gl/", "gl/x", "nosuch", "./a.txt", "a.txt/", "dir//b.txt", "", "./", "./dir/./b.txt",
         "dir/../a.txt", "../a.txt", "/a.txt", "f.txt", "s.txt", "o1.txt", "dir/nosuch", "./dir/",
         ".", "..", "./.", "dir/.", "ca.txt", "cb.txt"]
reflog = ["@{0}", "@{1}", "@{2}", "@{3}", "@{5}", "@{8}", "@{12}", "@{30}", "@{99}", "@{-1}", "@{-2}",
          "@{-3}", "@{-4}", "@{-6}", "@{-0}", "@{-99}", "@{u}", "@{U}", "@{upstream}", "@{push}", "@{PUSH}",
          "@{1700000150}", "@{1700000050}", "@{1700000055}", "@{1700000070}", "@{1700009999}",
          "@{100000000}", "@{99999999}", "@{}", "@{x}", "@{-1}@{u}"]


def rev(depth=None):
    text = atom()
    for _ in range(rng.choice([0, 0, 1, 1, 2, 3]) if depth is None else depth):
        text += rng.choice(suffixes)()
    return text


def reflog_rev():
    base = rng.choice(head_names + ["", "", "stash", "refs/stash", "refs/heads/master", "ambig", "v1", "origin"])
    if base == "@":
        base = ""
    text = base + rng.choice(reflog)
    if rng.random() < 0.3:
        text += rng.choice(suffixes)()
    return text


def one():
    r = rng.random()
    if kind == "plain":
        r = r * 0.75
    elif kind == "range":
        r = 0.55 + r * 0.30
    if r < 0.30:
        return rev()
    if r < 0.42:
        return reflog_rev()
    if r < 0.55:
        return rev(rng.choice([0, 0, 1])) + ":" + rng.choice(paths)
    if r < 0.65:
        return rng.choice([":", ":0:", ":1:", ":2:", ":3:", ":4:", "::", ":./"]) + rng.choice(paths)
    if r < 0.75:
        return ":/" + rng.choice(["", "!-", "!!", "!"]) + rng.choice(patterns)
    if r < 0.85:
        a = rev(rng.choice([0, 0, 1])) if rng.random() < 0.9 else ""
        b = rev(rng.choice([0, 0, 1])) if rng.random() < 0.9 else ""
        return a + rng.choice(["..", "...", "..", ".", "....", ".. "]) + b
    if r < 0.95:
        return rng.choice(["", "", "^"]) + rev(rng.choice([0, 1])) + rng.choice(["^@", "^!", "^-", "^-1", "^-2", "^-3", "^-0", "^@x", "^!x", "^-x"])
    return "^" + rev()


for _ in range(count):
    print(one())
