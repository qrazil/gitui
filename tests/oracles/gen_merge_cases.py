#!/usr/bin/env python3
"""Seeded generator of base/ours/theirs triples for the diff3 and xdiff oracles.

    gen_merge_cases.py SEED COUNT DIR [SIZES [ROUNDS]]

SIZES is a comma list of file lengths in lines to draw from (default
0,1,2,3,5,8,12,20,40,80); a long one exercises xdiff's large-input heuristics.  ROUNDS is the same for
how many random edits each side gets (default 0,1,1,1,2,2,3,5); hundreds of them
make two files differ enough for those heuristics to engage; -1 is a fresh
random file of the same length.

writes DIR/NNNNN.base, .ours and .theirs.  The cases are shaped to hit the places
where a line merge is easy to get wrong: a small alphabet so lines repeat, empty
lines, block moves and duplications, edits that touch or overlap, identical edits
on both sides, CRLF files and mixed endings, and a missing newline at EOF.
"""
import os
import random
import sys

ALPHA = [b"a", b"b", b"c", b"d", b"e", b"", b"{", b"}", b"x = 1", b"x = 2",
         b"return", b"  ", b"if (x) {", b"}", b"// c", b"1", b"2", b"3"]


def lines(rng, n, pool):
    return [rng.choice(pool) for _ in range(n)]


def edit(rng, ls, pool, rounds):
    n_edits = rng.choice(rounds)
    if n_edits < 0:
        return lines(rng, len(ls), pool)  # a fresh file: nothing in common but the alphabet
    ls = list(ls)
    for _ in range(n_edits):
        kind = rng.choice(["rep", "ins", "del", "move", "dup", "insblock", "delblock"])
        n = len(ls)
        if kind == "rep" and n:
            ls[rng.randrange(n)] = rng.choice(pool)
        elif kind == "ins":
            ls.insert(rng.randrange(n + 1), rng.choice(pool))
        elif kind == "del" and n:
            del ls[rng.randrange(n)]
        elif kind == "move" and n > 2:
            i = rng.randrange(n)
            j = min(n, i + rng.randint(1, 4))
            blk = ls[i:j]
            del ls[i:j]
            k = rng.randint(0, len(ls))
            ls[k:k] = blk
        elif kind == "dup" and n:
            i = rng.randrange(n)
            j = min(n, i + rng.randint(1, 3))
            k = rng.randint(0, n)
            ls[k:k] = ls[i:j]
        elif kind == "insblock":
            k = rng.randint(0, n)
            ls[k:k] = lines(rng, rng.randint(2, 6), pool)
        elif kind == "delblock" and n > 1:
            i = rng.randrange(n)
            j = min(n, i + rng.randint(2, 5))
            del ls[i:j]
    return ls


def render(rng, ls, eol, final_nl):
    out = b""
    for i, l in enumerate(ls):
        out += l
        if i < len(ls) - 1 or final_nl:
            e = eol
            if eol == b"mixed":
                e = rng.choice([b"\n", b"\r\n"])
            out += e
    return out


def main():
    seed, count, d = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    os.makedirs(d, exist_ok=True)
    rng = random.Random(seed)
    rounds = [int(x) for x in sys.argv[5].split(",")] if len(sys.argv) > 5 else [0, 1, 1, 1, 2, 2, 3, 5]
    sizes = [int(x) for x in sys.argv[4].split(",")] if len(sys.argv) > 4 else [0, 1, 2, 3, 5, 8, 12, 20, 40, 80]
    for c in range(count):
        size = rng.choice(sizes)
        pool = rng.sample(ALPHA, rng.choice([3, 5, 8, len(ALPHA)]))
        if rng.random() < 0.3:
            pool = pool + [b"u%d" % i for i in range(40)]
        base = lines(rng, size, pool)
        ours = edit(rng, base, pool, rounds)
        theirs = edit(rng, base, pool, rounds)
        r = rng.random()
        if r < 0.08:
            theirs = list(ours)  # identical change on both sides
        elif r < 0.12:
            theirs = list(base)
        elif r < 0.16:
            ours = list(base)
        eol = rng.choice([b"\n"] * 10 + [b"\r\n", b"mixed"])
        # one sided CRLF is the interesting case for the conflict-marker newline
        eols = [eol, eol, eol]
        if rng.random() < 0.05:
            eols[rng.randrange(3)] = rng.choice([b"\n", b"\r\n"])
        nls = [rng.random() > 0.12 for _ in range(3)]
        if rng.random() < 0.5:
            nls = [nls[0]] * 3
        for name, ls, e, nl in zip(("base", "ours", "theirs"), (base, ours, theirs), eols, nls):
            with open(os.path.join(d, "%05d.%s" % (c, name)), "wb") as f:
                f.write(render(rng, ls, e, nl))


main()
