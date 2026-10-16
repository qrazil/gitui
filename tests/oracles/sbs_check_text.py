#!/usr/bin/env python3
"""An oracle for the text layout that shares no code with it.

    python3 tests/oracles/sbs_check_text.py <unified.diff> <side-by-side.txt> <width>

Reads git's own unified diff for the removed and added lines of each file, reads
the side-by-side text at the geometry the engine documents (each side: a number
column, a space, a marker column, the text; a 3-column gutter between), and
checks that the `-` cells on the left are exactly the removed lines and the `+`
cells on the right exactly the added lines, in order. Lines with tabs, wide
characters or that wrap are left out of both sides (their cells are not a
simple slice). Prints `ok` or what differs.
"""
import re
import sys


def main():
    diff_path, sbs_path, width = sys.argv[1], sys.argv[2], int(sys.argv[3])
    removed, added = [], []
    in_hunk = False
    for line in open(diff_path, encoding="utf-8").read().split("\n"):
        if line.startswith("diff --git"):
            in_hunk = False
        elif line.startswith("@@ "):
            in_hunk = True
        elif in_hunk and line.startswith("-"):
            removed.append(line[1:])
        elif in_hunk and line.startswith("+"):
            added.append(line[1:])

    def simple(text):
        return not any(ord(c) > 126 or c == "\t" for c in text) and len(text) < 30

    numbers = 2
    avail = width - 3
    left_w = avail // 2
    got_removed, got_added = [], []
    for row in open(sbs_path, encoding="utf-8").read().split("\n"):
        if row.startswith("@@") or len(row) < 5 or row.startswith("\\e"):
            continue
        row = row.ljust(width)
        left, right = row[:left_w], row[left_w + 3:]
        if left[numbers + 1] == "-" and left[:numbers].strip().isdigit():
            got_removed.append(left[numbers + 2:].rstrip().rstrip("\u240d"))
        if right[numbers + 1] == "+" and right[:numbers].strip().isdigit():
            got_added.append(right[numbers + 2:].rstrip().rstrip("\u240d"))
    want_removed = [t.rstrip() for t in removed if simple(t) and t.strip() != ""]
    want_added = [t.rstrip() for t in added if simple(t) and t.strip() != ""]
    got_removed = [t for t in got_removed if simple(t) and t.strip() != ""]
    got_added = [t for t in got_added if simple(t) and t.strip() != ""]
    problems = []
    if got_removed != want_removed:
        problems.append("left side: %r != removed lines %r" % (got_removed, want_removed))
    if got_added != want_added:
        problems.append("right side: %r != added lines %r" % (got_added, want_added))
    print("ok" if not problems else "\n".join(problems))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
