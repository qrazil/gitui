#!/usr/bin/env bash
# `GIT_hunks.m31`: the generic edit script from `lib/diff.m31`, grouped into
# qrazil/tui's `TUI_diff_view.Hunk`/`Line` with context -- checked against real
# `diff -u` (hunk boundaries and line classification) and real `git diff`
# (the binary-file case, since git's own NUL heuristic is what
# `lib/diff.m31`'s `is_binary` matches).
#
# Sourced from `test.sh`, on the same terms as `test_write.sh`: no `set`, no
# `cd`, no `trap` here, and `$WORK`, `$LANGC`, `$M31_ROOT`,
# `note`/`bad` and the `pass`/`fail` counters are all `test.sh`'s.

if build t_hunks; then
    t_hunks="$WORK/t_hunks"
    hdir="$WORK/hunks-fixtures"
    mkdir -p "$hdir"

    # Each pair is compared two ways: `t_hunks`'s own output against real
    # `diff -u`'s body (its `---`/`+++` file-header lines stripped, and any
    # `\ No newline at end of file` marker dropped -- `TUI_diff_view.Line` has
    # no way to carry that annotation, only the text of a line, so this is
    # the one place the two are allowed to differ; the ROUND-TRIP property in
    # `corpus/modules/stdlib-diff` is what actually proves the no-trailing-
    # newline case is handled correctly).
    oracle_case() {
        local name=$1 old=$2 new=$3
        local got want
        got=$("$t_hunks" "$old" "$new")
        want=$(diff -u "$old" "$new" | tail -n +3 | grep -v '^\\ No newline')
        if [ "$got" = "$want" ]; then
            note "hunks vs diff -u: $name"
        else
            bad "hunks vs diff -u: $name" "$(diff <(echo "$got") <(echo "$want"))"
        fi
    }

    mk() { printf '%b' "$2" >"$hdir/$1"; }

    mk a.txt 'a\nb\nc\n'
    mk b.txt 'a\nb\nc\n'
    oracle_case "no change" "$hdir/a.txt" "$hdir/b.txt"

    mk a.txt 'a\nb\n'
    mk b.txt 'a\nx\ny\nz\nb\n'
    oracle_case "pure addition" "$hdir/a.txt" "$hdir/b.txt"

    mk a.txt 'a\nx\ny\nz\nb\n'
    mk b.txt 'a\nb\n'
    oracle_case "pure deletion" "$hdir/a.txt" "$hdir/b.txt"

    mk a.txt '1\n2\n3\n4\n5\n6\n7\n8\n9\n'
    mk b.txt '1\n2\n3\nX\n5\n6\n7\n8\n9\n'
    oracle_case "change with context both sides" "$hdir/a.txt" "$hdir/b.txt"

    mk a.txt 'a\nb\nc\nd\ne\n'
    mk b.txt 'Z\nb\nc\nd\ne\n'
    oracle_case "change at the very start (no leading context)" "$hdir/a.txt" "$hdir/b.txt"

    mk a.txt 'a\nb\nc\nd\ne\n'
    mk b.txt 'a\nb\nc\nd\nZ\n'
    oracle_case "change at the very end (no trailing context)" "$hdir/a.txt" "$hdir/b.txt"

    : >"$hdir/empty.txt"
    mk full.txt 'a\nb\nc\n'
    oracle_case "empty old" "$hdir/empty.txt" "$hdir/full.txt"
    oracle_case "empty new" "$hdir/full.txt" "$hdir/empty.txt"
    oracle_case "both empty" "$hdir/empty.txt" "$hdir/empty.txt"

    mk a.txt 'a\nb\nc'
    mk b.txt 'a\nb\nX\n'
    oracle_case "no trailing newline, old side" "$hdir/a.txt" "$hdir/b.txt"

    mk a.txt '1\n2\n3\n4\n5\n6\n7\n'
    mk b.txt '1\nA\n3\n4\n5\nB\n7\n'
    oracle_case "adjacent changes merge into one hunk" "$hdir/a.txt" "$hdir/b.txt"

    mk a.txt '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n'
    mk b.txt '1\nA\n3\n4\n5\n6\n7\n8\n9\nB\n11\n'
    oracle_case "distant changes stay in separate hunks" "$hdir/a.txt" "$hdir/b.txt"

    python3 - "$hdir/rand_a.txt" "$hdir/rand_b.txt" <<'PY'
import random, sys
random.seed(99)
lines = [f"line {i}" for i in range(150)]
old = list(lines)
new = list(lines)
for _ in range(12):
    i = random.randrange(len(new))
    op = random.choice(["mod", "del", "ins"])
    if op == "mod":
        new[i] = new[i] + " CHANGED"
    elif op == "del" and len(new) > 1:
        del new[i]
    else:
        new.insert(i, "INSERTED " + str(i))
open(sys.argv[1], "w").write("\n".join(old) + "\n")
open(sys.argv[2], "w").write("\n".join(new) + "\n")
PY
    oracle_case "a larger file with scattered changes" "$hdir/rand_a.txt" "$hdir/rand_b.txt"

    # Hunks are cut from `GIT_xdiff`'s edit script, which is git's: so, unlike
    # GNU diff, which breaks ties between equally long scripts its own way, the
    # body must equal `git diff --no-indent-heuristic -U3` on files whose lines
    # repeat (where the choice of script matters most).
    python3 - "$hdir" <<'PY'
import random, sys
rng = random.Random(7)
for n in range(80):
    pool = ["", "}", "{", "x", "y", "return", "a", "b"][: rng.randint(2, 8)]
    old = [rng.choice(pool) for _ in range(rng.randint(0, 60))]
    new = list(old)
    for _ in range(rng.randint(0, 8)):
        i = rng.randint(0, len(new))
        if new and rng.random() < 0.4:
            del new[min(i, len(new) - 1)]
        else:
            new.insert(i, rng.choice(pool))
    for name, ls in (("old", old), ("new", new)):
        open("%s/gd%02d.%s" % (sys.argv[1], n, name), "w").write("".join(l + "\n" for l in ls))
PY
    gd_bad=0 gd_n=0
    for gd in "$hdir"/gd*.old; do
        gd_stem=${gd%.old}
        gd_n=$((gd_n + 1))
        gd_got=$("$t_hunks" "$gd_stem.old" "$gd_stem.new" | sed 's/^@@ -\([0-9]*\),1 /@@ -\1 /; s/^\(@@ [^+]*+[0-9]*\),1 @@/\1 @@/')
        gd_want=$(git diff --no-index --no-indent-heuristic -U3 "$gd_stem.old" "$gd_stem.new" | sed -n '/^@@ /,$p' | sed 's/^\(@@ [^@]*@@\).*/\1/')  # git leaves out a count of 1 and adds a function name
        if [ "$gd_got" != "$gd_want" ]; then
            gd_bad=$((gd_bad + 1))
            [ $gd_bad -le 2 ] && bad "hunks vs git diff: $(basename "$gd_stem")" "$(diff <(echo "$gd_got") <(echo "$gd_want") | head -10)"
        fi
    done
    [ $gd_bad -eq 0 ] && note "hunks vs git diff --no-indent-heuristic: $gd_n repetitive-line pairs identical"

    # --- binary detection, against real `git diff` ---------------------------
    #
    # A disposable fixture repository, built and torn down with everything
    # else under `$WORK` -- never a real repository, this one included.
    bindir="$WORK/hunks-bin-fixture"
    mkdir -p "$bindir"
    (
        set -e
        cd "$bindir"
        git init -q -b main .
        git config user.email h@example.com
        git config user.name 'Hunks Tester'
        printf 'hello\000world\n' >bin.dat
        git add -A
        GIT_AUTHOR_DATE='1700000000 +0000' GIT_COMMITTER_DATE='1700000000 +0000' \
            git commit -q -m 'a NUL-bearing file'
        printf 'hello\000world\000more\n' >bin.dat
    ) >"$WORK/hunks-bin.log" 2>&1 || bad "binary fixture repository" "$(tail -5 "$WORK/hunks-bin.log")"

    if git -C "$bindir" diff --no-color 2>/dev/null | grep '^Binary files' >/dev/null; then
        git -C "$bindir" show HEAD:bin.dat >"$hdir/bin_old.dat"
        cp "$bindir/bin.dat" "$hdir/bin_new.dat"
        got=$("$t_hunks" "$hdir/bin_old.dat" "$hdir/bin_new.dat")
        if [ "$got" = "Binary files differ" ]; then
            note "hunks vs git diff: a NUL-bearing file is reported binary, not line-diffed"
        else
            bad "hunks vs git diff: binary file" "hunks.hunks said: $got"
        fi
    else
        bad "binary fixture: git diff did not call the fixture binary"
    fi
fi
