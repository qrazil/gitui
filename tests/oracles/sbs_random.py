#!/usr/bin/env python3
"""Random old/new file pairs for the side-by-side property tests.

    python3 tests/oracles/sbs_random.py <outdir> <count> [seed]

Each pair is `<outdir>/rN.old` and `rN.new`: a few dozen lines drawn from a
small vocabulary (so the diff pairs and pads in every proportion), with tabs,
wide characters, emoji, a long line now and then, and sometimes no final
newline or CRLF endings. The same seed gives the same files.
"""
import os
import random
import sys

WORDS = ["alpha", "beta", "gamma", "delta", "x", "if", "(", ")", "{", "}", ";", "=", "日本", "語", "😀", "é", "\t", "  ", "foo_bar", "123"]


def line(rng):
    n = rng.choice([0, 1, 2, 3, 5, 8, 14])
    text = " ".join(rng.choice(WORDS) for _ in range(n))
    if rng.random() < 0.03:
        text = text + " " + "long " * rng.randint(30, 90)
    return text


def main():
    out = sys.argv[1]
    count = int(sys.argv[2])
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    rng = random.Random(seed)
    os.makedirs(out, exist_ok=True)
    for i in range(count):
        old = [line(rng) for _ in range(rng.randint(0, 40))]
        new = list(old)
        for _ in range(rng.randint(0, 8)):
            kind = rng.choice(["edit", "insert", "delete", "block"])
            if kind == "edit" and new:
                new[rng.randrange(len(new))] = line(rng)
            elif kind == "insert":
                new.insert(rng.randint(0, len(new)), line(rng))
            elif kind == "delete" and new:
                del new[rng.randrange(len(new))]
            elif kind == "block":
                at = rng.randint(0, len(new))
                new[at:at + rng.randint(0, 5)] = [line(rng) for _ in range(rng.randint(0, 6))]
        eol = "\r\n" if rng.random() < 0.15 else "\n"
        for name, content in (("old", old), ("new", new)):
            data = eol.join(content)
            if content and rng.random() > 0.15:
                data += eol
            with open(os.path.join(out, "r%d.%s" % (i, name)), "wb") as f:
                f.write(data.encode("utf-8"))


if __name__ == "__main__":
    main()
