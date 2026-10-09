# The overlay stack, the key table and the overlays' own logic -- unit-level,
# no repository and no terminal (the pty half is in `pty_e2e.py`, run by
# `test_gitui.sh`).
#
# Sourced from `test.sh`, which is why there is no `set`, no `cd` and no
# `trap` here -- see `test_write.sh`'s own header for why.

if build t_uikeys; then
    "$WORK/t_uikeys" >"$WORK/uikeys.out" 2>"$WORK/uikeys.err"
    if grep -q 'FAIL' "$WORK/uikeys.out"; then
        bad "ui keys: unit tests (t_uikeys)" "$(grep 'FAIL' "$WORK/uikeys.out")" "$(cat "$WORK/uikeys.err")"
    elif ! tail -1 "$WORK/uikeys.out" | grep -q ' 0 failed'; then
        bad "ui keys: unit tests (t_uikeys) did not finish" "$(tail -3 "$WORK/uikeys.out")" "$(cat "$WORK/uikeys.err")"
    else
        note "ui keys: unit tests -- $(tail -1 "$WORK/uikeys.out")"
    fi
fi
