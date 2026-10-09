#!/usr/bin/env bash
# `GIT_patch.m31`: staging and unstaging single lines (`apply_lines`,
# `revert_lines`).
#
# The oracle is `git apply` itself (`oracles/oracle_lines.py`): the same
# selection of an edit script is built as a patch -- selected `-`/`+` lines
# kept, an unselected `-` turned into context (staging) or an unselected `+`
# (unstaging), the other unselected change left out -- and applied with
# `git apply --cached` / `git apply --cached -R` to a blob in a disposable
# repository (`git fsck --strict` after each). The bytes must be the same, and
# so must the numbering of the ops (t_lines lists them, git's own
# `diff -U1000000` is the reference).
#
#   named     hand-written cases with the expected bytes spelled out as well:
#             deleting only, adding only, mixed, file addition, file deletion,
#             an empty selection, a missing newline at the end of file (every
#             combination), CRLF, repeated lines; plus the refusals (a text the
#             ops were not made from, an index no op has -> None).
#   random    the cases of `gen_merge_cases.py` as old = base, new = ours, with
#             a random selection (all, none, removals, additions, one line, a
#             run, a subset).
#
# Sourced from `test.sh`, on the same terms as `test_patch.sh`.

if build t_lines; then
    ln_dir="$WORK/lines-named"
    mkdir -p "$ln_dir" "$WORK/lines-scratch"
    ln_count=$(python3 tests/oracles/oracle_lines.py prepare-named "$ln_dir" 2>"$WORK/lines.err")
    if [ -n "$ln_count" ] \
       && "$WORK/t_lines" "$ln_dir" "$ln_count" >"$WORK/lines.out" 2>>"$WORK/lines.err" \
       && python3 tests/oracles/oracle_lines.py check "$ln_dir" "$ln_count" "$WORK/lines-scratch" >"$WORK/lines.cmp" 2>>"$WORK/lines.err" \
       && grep -q ', 0 failed$' "$WORK/lines.cmp"; then
        note "line staging vs git apply, hand-written cases: $(tail -1 "$WORK/lines.cmp")"
    else
        bad "line staging vs git apply, hand-written cases" "$(head -8 "$WORK/lines.cmp" 2>/dev/null)" "$(head -5 "$WORK/lines.out")" "$(head -5 "$WORK/lines.err")"
    fi
    rm -rf "$ln_dir"

    ln_dir="$WORK/lines-random"
    ln_count=1500
    python3 tests/oracles/gen_merge_cases.py 51 "$ln_count" "$ln_dir" 0,1,2,3,5,8,12,20,40 0,1,1,2,2,3,5 2>"$WORK/lines.err" \
        && python3 tests/oracles/oracle_lines.py prepare "$ln_dir" "$ln_count" 52 2>>"$WORK/lines.err" \
        && "$WORK/t_lines" "$ln_dir" "$ln_count" >"$WORK/lines.out" 2>>"$WORK/lines.err" \
        && python3 tests/oracles/oracle_lines.py check "$ln_dir" "$ln_count" "$WORK/lines-scratch" >"$WORK/lines.cmp" 2>>"$WORK/lines.err"
    if grep -q ', 0 failed$' "$WORK/lines.cmp" 2>/dev/null; then
        note "line staging vs git apply, random selections: $(tail -1 "$WORK/lines.cmp")"
    else
        bad "line staging vs git apply, random selections" "$(head -8 "$WORK/lines.cmp" 2>/dev/null)" "$(head -5 "$WORK/lines.out")" "$(head -5 "$WORK/lines.err")"
    fi
    rm -rf "$ln_dir" "$WORK/lines-scratch"
fi
