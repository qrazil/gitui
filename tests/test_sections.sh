# Sections and the statusline: the section model and the statusline text
# (`t_sections`, no repository and no terminal), and `[`/`]`, folding,
# the persisted fold list, the statusline's contents and the `i` overview under a
# real pty (`pty_sections.py`). Sourced from `test.sh` right after
# `test_gitui.sh`, whose `$WORK/gitui` build it reuses (built here when that
# is missing). No `set`, no `cd` and no `trap`: see `test_write.sh`'s header.

if build t_sections; then
    "$WORK/t_sections" >"$WORK/sections.out" 2>"$WORK/sections.err"
    if grep -q 'FAIL' "$WORK/sections.out"; then
        bad "sections: unit tests (t_sections)" "$(grep 'FAIL' "$WORK/sections.out")" "$(cat "$WORK/sections.err")"
    elif ! tail -1 "$WORK/sections.out" | grep -q ' 0 failed'; then
        bad "sections: unit tests (t_sections) did not finish" "$(tail -3 "$WORK/sections.out")" "$(cat "$WORK/sections.err")"
    else
        note "sections: unit tests -- $(tail -1 "$WORK/sections.out")"
    fi
fi

if [ ! -x "$WORK/gitui" ]; then
    bash scripts/build.sh -o "$WORK/gitui" >"$WORK/sections_build.log" 2>&1 \
        || bad "sections: scripts/build.sh" "$(cat "$WORK/sections_build.log")"
fi
if [ -x "$WORK/gitui" ] && command -v python3 >/dev/null; then
    if out=$(python3 tests/pty_sections.py "$WORK/gitui" "$WORK/ptysections" 2>&1); then
        note "gitui sections pty: $(echo "$out" | grep -c '^ok') checks (sections, folds, hunks, statusline, overview)"
    else
        bad "gitui sections pty" "$(echo "$out" | grep -v '^ok' | head -30)"
    fi
fi
