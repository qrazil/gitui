#!/usr/bin/env bash
# `GIT_diff3.m31`: the three-way merge and the conflict reader.
#
#   t_conflicts   hand-written cases with the expected bytes spelled out, and the
#                 parse/render/resolve round trips.
#   t_diff3       thousands of seeded random base/ours/theirs triples
#                 (`oracles/gen_merge_cases.py`: repeated and empty lines, moved
#                 and duplicated blocks, CRLF, a missing final newline, empty
#                 files; then long files), merged by this code and by
#                 `git merge-file -p` and `git merge-file -p --diff3`, which must
#                 give the same bytes and the same number of conflicts
#                 (`oracles/oracle_diff3.py`). `Level.Zealous` has no
#                 merge-file switch, so a few hundred of the triples are also
#                 merged by a real `git merge -s recursive -X diff-algorithm=myers`
#                 in disposable repositories (`oracles/oracle_zealous.py`; Myers
#                 like merge-file -- the strategies' default differs between git
#                 versions).
#
# Sourced from `test.sh`, on the same terms as `test_patch.sh`: no `set`, no
# `cd`, no `trap` here, and `$WORK`, `$LANGC`, `$M31_ROOT`,
# `note`/`bad` and the `pass`/`fail` counters are all `test.sh`'s.

if build t_conflicts; then
    "$WORK/t_conflicts" >"$WORK/conflicts.out" 2>"$WORK/conflicts.err"
    if grep -q ' FAIL' "$WORK/conflicts.out" || ! grep -q ', 0 failed$' "$WORK/conflicts.out"; then
        bad "diff3: hand-written merge and conflict-reader cases (t_conflicts)" "$(grep ' FAIL' "$WORK/conflicts.out" | head -10)" "$(tail -1 "$WORK/conflicts.out")" "$(cat "$WORK/conflicts.err")"
    else
        note "diff3: hand-written merge and conflict-reader cases -- $(tail -1 "$WORK/conflicts.out")"
    fi
fi

if build t_diff3; then
    d3_gen=tests/oracles/gen_merge_cases.py
    # name  seed  count  sizes  rounds
    for spec in \
        "small-files 41 2500 0,1,2,3,5,8,12,20,40,80 0,1,1,1,2,2,3,5" \
        "many-edits 42 600 8,20,40,80,200 5,10,20,40" \
        "long-files 43 100 1500,3000 40,300,-1"; do
        set -- $spec
        d3_name=$1 d3_seed=$2 d3_count=$3
        d3_dir="$WORK/diff3-$d3_name"
        python3 "$d3_gen" "$d3_seed" "$d3_count" "$d3_dir" "$4" "$5" 2>"$WORK/diff3.err" \
            && "$WORK/t_diff3" "$d3_dir" "$d3_count" >"$WORK/diff3.out" 2>>"$WORK/diff3.err" \
            && python3 tests/oracles/oracle_diff3.py "$d3_dir" "$d3_count" >"$WORK/diff3.cmp" 2>>"$WORK/diff3.err"
        if grep -q ', 0 failed$' "$WORK/diff3.cmp" 2>/dev/null; then
            note "diff3 vs git merge-file, plain and --diff3 ($d3_name): $(tail -1 "$WORK/diff3.cmp")"
        else
            bad "diff3 vs git merge-file ($d3_name)" "$(head -8 "$WORK/diff3.cmp" 2>/dev/null)" "$(head -5 "$WORK/diff3.out")" "$(head -5 "$WORK/diff3.err")"
        fi
        if [ "$d3_name" = small-files ]; then
            mkdir -p "$WORK/diff3-repos"
            if python3 tests/oracles/oracle_zealous.py "$d3_dir" 200 "$WORK/diff3-repos" >"$WORK/diff3.zeal" 2>"$WORK/diff3.err" \
               && grep -q ', 0 failed$' "$WORK/diff3.zeal"; then
                note "diff3 Level.Zealous vs git merge -s recursive -X diff-algorithm=myers: $(tail -1 "$WORK/diff3.zeal")"
            else
                bad "diff3 Level.Zealous vs git merge -s recursive -X diff-algorithm=myers" "$(head -8 "$WORK/diff3.zeal")" "$(head -5 "$WORK/diff3.err")"
            fi
            rm -rf "$WORK/diff3-repos"
        fi
        rm -rf "$d3_dir"
    done
fi
