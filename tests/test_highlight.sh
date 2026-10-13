# Syntax highlighting: the pure line styling (`t_highlight`), and the diff,
# blame and commit views, the 5000-line scroll and the switches under a real
# pty (`pty_highlight.py`). Sourced from `test.sh` right after `test_gitui.sh`,
# whose `$WORK/gitui` build it reuses (built here when that is missing).

if build t_highlight; then
    "$WORK/t_highlight" >"$WORK/highlight.out" 2>"$WORK/highlight.err"
    if grep -q 'FAIL' "$WORK/highlight.out"; then
        bad "highlight: unit tests (t_highlight)" "$(grep 'FAIL' "$WORK/highlight.out")" "$(cat "$WORK/highlight.err")"
    elif ! tail -1 "$WORK/highlight.out" | grep -q ' 0 failed'; then
        bad "highlight: unit tests (t_highlight) did not finish" "$(tail -3 "$WORK/highlight.out")" "$(cat "$WORK/highlight.err")"
    else
        note "highlight: unit tests -- $(tail -1 "$WORK/highlight.out")"
    fi
fi

if [ ! -x "$WORK/gitui" ]; then
    bash scripts/build.sh -o "$WORK/gitui" >"$WORK/highlight_build.log" 2>&1 \
        || bad "highlight: scripts/build.sh" "$(cat "$WORK/highlight_build.log")"
fi
if [ -x "$WORK/gitui" ] && command -v python3 >/dev/null; then
    if out=$(python3 tests/pty_highlight.py "$WORK/gitui" "$WORK/ptyhighlight" 2>&1); then
        note "gitui highlight pty: $(echo "$out" | grep -c '^ok') checks (colours, scrolling 5000 lines, switches)"
    else
        bad "gitui highlight pty" "$(echo "$out" | grep -v '^ok' | head -30)"
    fi
fi
