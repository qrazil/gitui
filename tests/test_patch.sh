# `GIT_patch.m31`: applying or reverting exactly one hunk of a diff, byte for
# byte -- the piece the diff view's `s`/`u` (hunk-level staging) is built
# on. `t_patch.m31` checks the round-trip properties with no repository at
# all; `test_gitui.sh`'s own "gitui hunk:" checks are where the result is
# compared against real `git apply --cached` and `git add -p`'s outcome.
#
# Sourced from `test.sh`, on the same terms as `test_hunks.sh`: no `set`,
# no `cd`, no `trap` here, and `$WORK`, `$LANGC`, `$M31_ROOT`,
# `note`/`bad` and the `pass`/`fail` counters are all `test.sh`'s.

if build t_patch; then
    "$WORK/t_patch" >"$WORK/patch.out" 2>"$WORK/patch.err"
    if grep -q ' FAIL' "$WORK/patch.out" || ! grep -q ', 0 failed$' "$WORK/patch.out"; then
        bad "patch: hunk apply/revert round trips (t_patch)" "$(grep ' FAIL' "$WORK/patch.out" | head -10)" "$(tail -1 "$WORK/patch.out")" "$(cat "$WORK/patch.err")"
    else
        note "patch: hunk apply/revert round trips -- $(tail -1 "$WORK/patch.out")"
    fi
fi
