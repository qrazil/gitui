#!/usr/bin/env python3
"""Plants objects whose names begin like existing ones, to test abbreviations.

    revparse_collide.py <work tree> <sha1|sha256>

For a handful of objects (a commit, its tree, an annotated tag, a blob) a loose
object of another type is written whose first four hex digits are the same, so
`git rev-parse <4 digits>` is ambiguous and only a type filter (`^{commit}`,
`^{tree}`, ...) breaks the tie. A second commit is planted next to a commit as
well: the same type on both sides stays ambiguous whatever the filter.
Deterministic: the same repository gives the same objects.
"""
import hashlib
import subprocess
import sys

repo, fmt = sys.argv[1], sys.argv[2]
algo = hashlib.sha1 if fmt == "sha1" else hashlib.sha256


def git(*args, data=None):
    out = subprocess.run(["git", "-C", repo, *args], input=data, capture_output=True)
    return out.stdout


def rev(spec):
    return git("rev-parse", spec).decode().strip()


def name_of(kind, body):
    return algo(("%s %d" % (kind, len(body))).encode() + b"\0" + body).hexdigest()


def write(kind, body):
    git("hash-object", "-w", "-t", kind, "--stdin", data=body)


empty_blob = rev("HEAD:a.txt")
raw = bytes.fromhex(empty_blob)


def make_blob(n):
    return b"collide %d\n" % n


def make_tree(n):
    return b"100644 c%d\0" % n + raw


head_tree = rev("HEAD^{tree}")


def make_commit(n):
    tree = head_tree
    return (
        "tree %s\nauthor C <c@example.com> %d +0000\ncommitter C <c@example.com> %d +0000\n\ncollide %d\n"
        % (tree, 1600000000 + n, 1600000000 + n, n)
    ).encode()


makers = {"blob": make_blob, "tree": make_tree, "commit": make_commit}


def plant(kind, target):
    """Write one object of `kind` whose name starts with `target`'s first 4 digits."""
    want = target[:4]
    n = 0
    while True:
        body = makers[kind](n)
        found = name_of(kind, body)
        if found.startswith(want) and found != target:
            write(kind, body)
            return
        n += 1


targets = [
    (rev("HEAD"), ["blob", "tree"]),
    (rev("HEAD^{tree}"), ["blob", "commit"]),
    (rev("v1"), ["blob", "commit"]),
    (rev("HEAD:a.txt"), ["tree", "commit"]),
    (rev("master~3"), ["commit"]),
    (rev("HEAD:dir"), ["blob"]),
]
for target, kinds in targets:
    for kind in kinds:
        plant(kind, target)
