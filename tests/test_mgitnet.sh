# mgit's fetch / pull / push handoff and the remote-branch switcher under a
# real pty (`pty_net.py`), against `git http-backend` with Basic auth on
# localhost. Sourced from `test.sh`: shares `$WORK`, `build`, `note`/`bad`.

if [ ! -x "$WORK/mgit" ]; then
    bash scripts/build.sh -o "$WORK/mgit" >"$WORK/mgitnet_build.log" 2>&1 \
        || bad "mgit net: scripts/build.sh" "$(cat "$WORK/mgitnet_build.log")"
fi
if [ -x "$WORK/mgit" ] && command -v python3 >/dev/null; then
    if out=$(python3 tests/pty_net.py "$WORK/mgit" "$WORK/ptynet" 2>&1); then
        note "mgit net pty: $(echo "$out" | grep -c '^ok') checks (fetch, pull, pull --rebase, push, remote branch, bad password)"
    else
        bad "mgit net pty" "$(echo "$out" | grep -v '^ok' | head -30)"
    fi
fi
