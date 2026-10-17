# The modes: the tab order and tab bar, the key map every mode's hint row,
# `?` help and command palette are generated from -- unit-level, no repository
# and no terminal (the pty half is `pty_modes.py`, below).
#
# Sourced from `test.sh`, which is why there is no `set`, no `cd` and no
# `trap` here -- see `test_write.sh`'s own header for why.

if build t_modes; then
    "$WORK/t_modes" >"$WORK/modes.out" 2>"$WORK/modes.err"
    if grep -q 'FAIL' "$WORK/modes.out"; then
        bad "modes: unit tests (t_modes)" "$(grep 'FAIL' "$WORK/modes.out")" "$(cat "$WORK/modes.err")"
    elif ! tail -1 "$WORK/modes.out" | grep -q ' 0 failed'; then
        bad "modes: unit tests (t_modes) did not finish" "$(tail -3 "$WORK/modes.out")" "$(cat "$WORK/modes.err")"
    else
        note "modes: unit tests -- $(tail -1 "$WORK/modes.out")"
    fi
fi

# The screen half: the tab bar, the hint row, the modes' keys, no cell past the
# last column and incremental updates equal to a full redraw, at 80x24,
# 120x40 and 40x12, read through `pyte`. It needs that library; without it the
# checks are skipped, not failed. `PYTE_PYTHON` names a Python that has it.
if [ ! -x "$WORK/mgit" ]; then
    bash scripts/build.sh -o "$WORK/mgit" >"$WORK/modes_build.log" 2>&1 \
        || bad "modes: scripts/build.sh" "$(cat "$WORK/modes_build.log")"
fi
pyte_python=${PYTE_PYTHON:-python3}
if [ -x "$WORK/mgit" ] && command -v "$pyte_python" >/dev/null 2>&1; then
    if "$pyte_python" -c 'import pyte' >/dev/null 2>&1; then
        if out=$("$pyte_python" tests/pty_modes.py "$WORK/mgit" "$WORK/ptymodes" 2>&1); then
            note "mgit modes pty: $(echo "$out" | grep -c '^ok') checks (tabs, hint row, per-mode keys, flows, no overflow, incremental = full redraw)"
        else
            bad "mgit modes pty" "$(echo "$out" | grep -v '^ok' | head -30)"
        fi
    else
        note "SKIP mgit modes pty: pyte is not installed (pip install pyte, or set PYTE_PYTHON)"
    fi
else
    note "SKIP mgit modes pty: python3 or the mgit build is missing"
fi
