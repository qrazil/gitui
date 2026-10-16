#!/usr/bin/env python3
"""Fixtures for the side-by-side layout tests: `<name>.old` / `<name>.new` pairs.

    python3 tests/oracles/sbs_fixtures.py <outdir>

Written fresh each run (so nothing binary lives in the repository), with the
bytes spelled out here: tabs, CRLF, a missing final newline, wide characters,
an escape sequence inside a line, one very long line.
"""
import os
import sys


def lines(*xs):
    return "".join(x + "\n" for x in xs).encode()


CASES = {
    "pure_add": (
        lines("a", "b", "c"),
        lines("a", "b", "c", "d", "e"),
    ),
    "pure_delete": (
        lines("a", "b", "c", "d", "e"),
        lines("a", "e"),
    ),
    "replace_more_added": (
        lines("head", "x1", "x2", "x3", "tail"),
        lines("head", "y1", "y2", "y3", "y4", "y5", "tail"),
    ),
    "replace_more_removed": (
        lines("head", "x1", "x2", "x3", "x4", "x5", "tail"),
        lines("head", "y1", "y2", "tail"),
    ),
    "moved_lines": (
        lines("one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"),
        lines("three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "one", "two"),
    ),
    "intraline": (
        lines("int total = compute(alpha, beta) + offset;", "return total;"),
        lines("int total = compute(alpha, gamma) + offset * 2;", "return total;"),
    ),
    "long_lines": (
        lines("short", "x" * 30 + " the quick brown fox jumps over the lazy dog " * 6 + "end", "tail"),
        lines("short", "x" * 30 + " the quick brown fox jumps over the lazy cat " * 6 + "END", "tail"),
    ),
    "tabs": (
        lines("\tindented", "a\tb\tc", "\t\tdeep"),
        lines("\tindented", "a\tb\tcc", "        deep"),
    ),
    "wide": (
        lines("日本語のテキスト", "emoji 😀 and café", "plain"),
        lines("日本語のテキスト変更", "emoji 😀😀 and café", "plain"),
    ),
    "wide_wrapped": (
        lines("日本語のテキスト" * 8, "end"),
        lines("日本語のテキスト" * 8 + "追加", "end"),
    ),
    "empty_old": (
        b"",
        lines("first", "second", "third"),
    ),
    "empty_new": (
        lines("first", "second", "third"),
        b"",
    ),
    "eof_old_missing": (
        b"a\nb\nc",
        b"a\nb\nc\n",
    ),
    "eof_new_missing": (
        b"a\nb\nc\n",
        b"a\nb\nc\nd",
    ),
    "eof_both_missing": (
        b"a\nb\nc",
        b"a\nB\nc",
    ),
    "crlf": (
        b"one\r\ntwo\r\nthree\r\n",
        b"one\r\nTWO\r\nthree\r\n",
    ),
    "crlf_to_lf": (
        b"one\r\ntwo\r\nthree\r\n",
        b"one\ntwo\nthree\n",
    ),
    "control": (
        b"plain\nbad \x1b[31mred\x1b[0m here\nbell \x07 and del \x7f\n",
        b"plain\nbad \x1b[32mgreen\x1b[0m here\nbell \x07 and del \x7f\n",
    ),
    "many_hunks": (
        lines(*["line %d" % i for i in range(1, 61)]),
        lines(*[("LINE %d" % i if i in (5, 30, 31, 58) else "line %d" % i) for i in range(1, 61)]),
    ),
    "syntax_state": (
        lines("/* a comment that", "   spans lines: return 1; */", "int x = 1;"),
        lines("int x = 1;", "return 2;"),
    ),
    "very_long": (
        lines("head", "ab " * 15000 + "end", "tail"),
        lines("head", "ab " * 15000 + "END", "tail"),
    ),
    "identical": (
        lines("same", "same"),
        lines("same", "same"),
    ),
    "binaryish": (
        b"\x00\x01\x02 binary\n",
        b"\x00\x01\x03 binary\n",
    ),
}


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for name, (old, new) in sorted(CASES.items()):
        with open(os.path.join(out, name + ".old"), "wb") as f:
            f.write(old)
        with open(os.path.join(out, name + ".new"), "wb") as f:
            f.write(new)
    print(" ".join(sorted(CASES)))


if __name__ == "__main__":
    main()
