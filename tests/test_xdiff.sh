#!/usr/bin/env bash
# `GIT_xdiff.m31`: the line diff that makes the choices git's xdiff makes --
# checked against real `git diff --no-index --no-indent-heuristic -U1000000`,
# which runs the same xdiff, so the two must print the same script line for
# line, wherever a shortest script is not unique (that is the whole point of
# the port: `lib/diff.m31`'s Myers picks another one, and a three-way merge on
# top of it would conflict in other places than git does).
#
# The inputs are seeded random base/ours/theirs files from
# `tests/oracles/gen_merge_cases.py`: a small alphabet so lines repeat, empty
# lines, moved and duplicated blocks, CRLF, a missing final newline, empty
# files; then long files with hundreds of edits, and unrelated long files,
# which is where xdiff's cost cut-off and its "good snake" heuristics engage.
# Each file is diffed against each other (3 pairs per case).
#
# Sourced from `test.sh`, on the same terms as `test_patch.sh`: no `set`, no
# `cd`, no `trap` here, and `$WORK`, `$LANGC`, `$M31_ROOT`,
# `note`/`bad` and the `pass`/`fail` counters are all `test.sh`'s.

if build t_xdiff; then
    xd_gen=tests/oracles/gen_merge_cases.py
    xd_oracle=tests/oracles/oracle_xdiff.py
    # name  seed  count  sizes  rounds
    for spec in \
        "small-files 31 800 0,1,2,3,5,8,12,20,40,80 0,1,1,1,2,2,3,5" \
        "heavy-edits 32 30 500,2000,5000 40,100,300,1000" \
        "unrelated-long-files 33 12 2000,4000 -1,300"; do
        set -- $spec
        xd_name=$1 xd_seed=$2 xd_count=$3
        xd_dir="$WORK/xdiff-$xd_name"
        python3 "$xd_gen" "$xd_seed" "$xd_count" "$xd_dir" "$4" "$5" 2>"$WORK/xdiff.err" \
            && "$WORK/t_xdiff" "$xd_dir" "$xd_count" >"$WORK/xdiff.out" 2>>"$WORK/xdiff.err" \
            && python3 "$xd_oracle" "$xd_dir" "$xd_count" >"$WORK/xdiff.cmp" 2>>"$WORK/xdiff.err"
        if grep -q ', 0 failed$' "$WORK/xdiff.cmp" 2>/dev/null; then
            note "xdiff vs git diff ($xd_name): $(tail -1 "$WORK/xdiff.cmp")"
        else
            bad "xdiff vs git diff ($xd_name)" "$(head -8 "$WORK/xdiff.cmp" 2>/dev/null)" "$(head -5 "$WORK/xdiff.out")" "$(head -5 "$WORK/xdiff.err")"
        fi
        rm -rf "$xd_dir"
    done
fi
