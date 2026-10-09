# Line-level staging in the diff view, driven under a pty against `git apply`
# (`pty_lines.py`). Sourced from `test.sh` right after `test_gitui.sh`, whose
# `$WORK/gitui` build it reuses (built here when that is missing).

if [ ! -x "$WORK/gitui" ]; then
    bash scripts/build-gitui.sh -o "$WORK/gitui" >"$WORK/uilines_build.log" 2>&1 \
        || bad "uilines: scripts/build-gitui.sh" "$(cat "$WORK/uilines_build.log")"
fi
if [ -x "$WORK/gitui" ] && command -v python3 >/dev/null; then
    if out=$(python3 tests/pty_lines.py "$WORK/gitui" "$WORK/ptylines" 2>&1); then
        note "gitui lines pty: $(echo "$out" | grep -c '^ok') line-staging checks agree with git apply"
    else
        bad "gitui lines pty" "$(echo "$out" | grep -v '^ok' | head -30)"
    fi
fi
