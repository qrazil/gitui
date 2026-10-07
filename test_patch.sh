# `patch.m31`: applying or reverting exactly one hunk of a diff, byte for
# byte -- the piece the diff view's `s`/`u` (hunk-level staging) is built
# on. `t_patch.m31` checks the round-trip properties with no repository at
# all; `test_gitui.sh`'s own "gitui hunk:" checks are where the result is
# compared against real `git apply --cached` and `git add -p`'s outcome.
#
# Sourced from `test.sh`, on the same terms as `test_hunks.sh`: no `set`,
# no `cd`, no `trap` here, and `$WORK`, `$LANGC`, `$M31_ROOT`, `$TUI_ROOT`,
# `note`/`bad` and the `pass`/`fail` counters are all `test.sh`'s.
# `patch.m31` imports `hunks.m31`, which imports qrazil/tui's
# `tuidiffview`, so this stages the same files `test_hunks.sh`'s
# `build_tui` does, plus `patch.m31`.

build_patch() {
    local name=$1
    local stage="$WORK/patch-stage"
    mkdir -p "$stage"
    cp "$TUI_ROOT/tuibuf.m31" "$TUI_ROOT/tuigeom.m31" "$TUI_ROOT/tuiscroll.m31" \
        "$TUI_ROOT/tuistyle.m31" "$TUI_ROOT/tuitext.m31" "$TUI_ROOT/tuidiffview.m31" \
        hunks.m31 patch.m31 "$name.m31" "$stage/"
    if ! "$LANGC" --emit-c "$stage/$name.m31" -o "$WORK/$name.c" 2>"$WORK/$name.diag"; then
        bad "compile $name (staged with qrazil/tui)" "$(head -5 "$WORK/$name.diag")"
        return 1
    fi
    if ! cc -O2 -Wall -Wextra -I "$M31_ROOT/runtime" -pthread -o "$WORK/$name" "$WORK/$name.c" \
           "$M31_ROOT/runtime/rt.c" "$M31_ROOT/runtime/scheduler.c" "$M31_ROOT/$RT_REACTOR_C" "$M31_ROOT/$RT_CTX_ASM" \
           2>"$WORK/$name.cc"; then
        bad "cc $name" "$(head -5 "$WORK/$name.cc")"
        return 1
    fi
    return 0
}

if build_patch t_patch; then
    "$WORK/t_patch" >"$WORK/patch.out" 2>"$WORK/patch.err"
    if grep -q ' FAIL' "$WORK/patch.out" || ! grep -q ', 0 failed$' "$WORK/patch.out"; then
        bad "patch: hunk apply/revert round trips (t_patch)" "$(grep ' FAIL' "$WORK/patch.out" | head -10)" "$(tail -1 "$WORK/patch.out")" "$(cat "$WORK/patch.err")"
    else
        note "patch: hunk apply/revert round trips -- $(tail -1 "$WORK/patch.out")"
    fi
fi
