# `GIT_wire.m31`: the transport-independent half of git's wire protocol, over
# a duplex stream. Three layers of evidence, none of them this module judging
# itself:
#
#   1. unit checks over hand-built bytes (`t_wire unit`): pkt-line framing,
#      the advertisement (empty repository, `version 1`, `ERR`, sha256), the
#      side-band bands, report-status, the exact request bodies, pack
#      verification;
#   2. the negotiation over an in-memory duplex stream whose server has a
#      bounded output buffer (`t_wire duplex`): 1000 haves in rounds of 256
#      with no unread reply ever waiting while the client writes, an early
#      stop on `ready`, and a control showing the detector does trip on the
#      stateless one-shot body;
#   3. the real thing: `git upload-pack` and `git receive-pack`, the very
#      processes an ssh server would exec, behind a TCP socket
#      (`wire_bridge.py`). Its advertisement is diffed against `git ls-remote`,
#      a fetch with 800 local haves (700 the server has never seen) is traced
#      from the server's side and its pack judged by `git index-pack
#      --strict` and `git fsck --strict`, and pushes (to an empty repository,
#      a fast-forward, a stale one) are judged by `git fsck --strict` on the
#      receiving side.
#
# Sourced from `test.sh`, sharing its shell, `$WORK`, `build`, `note`/`bad`.
# Starts no process that outlives it: the bridge exits when its parent shell
# does, and is also killed by its exact PID after each phase.

wr_root="$WORK/wire"
mkdir -p "$wr_root"

if build t_wire; then
    # --- 1 and 2. no server -------------------------------------------------
    for wr_mode in unit duplex; do
        "$WORK/t_wire" "$wr_mode" >"$wr_root/$wr_mode.out" 2>&1
        wr_ok=0
        wr_bad=0
        while IFS= read -r wr_line; do
            case "$wr_line" in
                "ok "*)
                    note "${wr_line#ok }"
                    wr_ok=$((wr_ok + 1))
                    ;;
                *)
                    bad "${wr_line#FAIL }"
                    wr_bad=$((wr_bad + 1))
                    ;;
            esac
        done <"$wr_root/$wr_mode.out"
        if [ "$wr_ok" -eq 0 ]; then
            bad "wire $wr_mode produced no passing checks" "$(head -3 "$wr_root/$wr_mode.out")"
        fi
    done

    # --- 3. real git behind a socket ----------------------------------------
    if command -v python3 >/dev/null 2>&1; then
        wr_start() { # <service> <repo> [trace-file]  ->  wr_port, wr_pid
            local service=$1 repo=$2 trace=${3:-}
            rm -f "$wr_root/port"
            if [ -n "$trace" ]; then
                GIT_TRACE_PACKET="$trace" python3 tests/wire_bridge.py "$service" "$repo" "$wr_root/port" &
            else
                python3 tests/wire_bridge.py "$service" "$repo" "$wr_root/port" &
            fi
            wr_pid=$!
            local tries=0
            while [ ! -s "$wr_root/port" ] && [ "$tries" -lt 100 ]; do
                sleep 0.05
                tries=$((tries + 1))
            done
            wr_port=$(cat "$wr_root/port" 2>/dev/null)
        }
        wr_stop() {
            kill "$wr_pid" >/dev/null 2>&1
            wait "$wr_pid" 2>/dev/null
        }

        cat >"$wr_root/gen.py" <<'PY'
import sys
# gen.py <ref> <count> <label> <first-timestamp> <parent-or->
ref, count, label, ts0, parent = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), sys.argv[5]
out = sys.stdout.buffer
for i in range(count):
    message = f"{label} commit {i}\n".encode()
    content = f"{label} {i}\n".encode()
    ts = ts0 + i * 60
    out.write(f"commit {ref}\nauthor Wire Test <wire@example.com> {ts} +0000\ncommitter Wire Test <wire@example.com> {ts} +0000\ndata {len(message)}\n".encode() + message)
    if i == 0 and parent != "-":
        out.write(f"from {parent}\n".encode())
    if i == 0 and parent == "-":
        out.write(b"M 100644 inline base.txt\ndata 5\nbase\n")
    out.write(f"M 100644 inline f.txt\ndata {len(content)}\n".encode() + content + b"\n")
PY
        export GIT_AUTHOR_NAME="Wire Test" GIT_AUTHOR_EMAIL=wire@example.com GIT_AUTHOR_DATE="1700000000 +0000"
        export GIT_COMMITTER_NAME="Wire Test" GIT_COMMITTER_EMAIL=wire@example.com GIT_COMMITTER_DATE="1700000000 +0000"

        wr_cli="$wr_root/cli.git"
        wr_srv="$wr_root/srv.git"
        (
            set -e
            git init -q --bare -b main "$wr_cli"
            python3 "$wr_root/gen.py" refs/heads/main 100 common 1600000000 - | git -C "$wr_cli" fast-import --quiet
            git clone -q --bare "$wr_cli" "$wr_srv"
            # The server moves on by 300 commits, plus a side branch and a tag...
            python3 "$wr_root/gen.py" refs/heads/main 300 server 1610000000 'refs/heads/main^0' | git -C "$wr_srv" fast-import --quiet
            git -C "$wr_srv" branch side main~5
            git -C "$wr_srv" tag -a v1 -m "release one" main~10
            # ...and the client by 700 of its own the server has never seen.
            python3 "$wr_root/gen.py" refs/heads/main 700 client 1620000000 'refs/heads/main^0' | git -C "$wr_cli" fast-import --quiet
        ) >"$wr_root/fixture.log" 2>&1 && note "wire: fixtures built (server 400 commits, a branch, an annotated tag; client 100 shared + 700 of its own)" ||
            bad "wire fixtures" "$(tail -8 "$wr_root/fixture.log")"

        # An empty repository is the receive-pack case, and a missing one the hang-up case.
        wr_empty="$wr_root/empty.git"
        git init -q --bare -b main "$wr_empty"

        # --- ls: the advertisement, against `git ls-remote` -----------------
        wr_start upload-pack "$wr_srv"
        "$WORK/t_wire" ls "$wr_port" git-upload-pack >"$wr_root/ls.out" 2>&1
        grep -v '^caps ' "$wr_root/ls.out" >"$wr_root/ls.refs"
        git ls-remote "$wr_srv" >"$wr_root/ls-remote.out" 2>/dev/null
        if diff -q "$wr_root/ls.refs" "$wr_root/ls-remote.out" >/dev/null; then
            note "wire: the advertisement over a socket matches 'git ls-remote' byte for byte ($(wc -l <"$wr_root/ls.refs" | tr -d ' ') refs, peeled tag included)"
        else
            bad "wire: advertisement differs from git ls-remote" "$(diff "$wr_root/ls.refs" "$wr_root/ls-remote.out" | head -6)"
        fi
        if grep -q '^caps .*side-band-64k' "$wr_root/ls.out" && grep -q '^caps .*multi_ack_detailed' "$wr_root/ls.out"; then
            note "wire: capabilities are read off the first ref line (side-band-64k, multi_ack_detailed)"
        else
            bad "wire: capabilities" "$(grep '^caps' "$wr_root/ls.out")"
        fi
        wr_stop

        # --- fetch: 800 haves, 700 of them unknown to the server ------------
        wr_trace="$wr_root/trace.txt"
        : >"$wr_trace"
        wr_start upload-pack "$wr_srv" "$wr_trace"
        wr_out=$("$WORK/t_wire" fetch "$wr_port" "$wr_cli" "$wr_root/fetch.pack" 2>&1)
        wr_stop
        wr_haves=$(printf '%s\n' "$wr_out" | sed -n 's/^haves //p')
        wr_pack_objects=$(printf '%s\n' "$wr_out" | sed -n 's/^pack [0-9]* //p')
        wr_sent_haves=$(grep -c 'upload-pack< have ' "$wr_trace")
        wr_flushes=$(grep -c 'upload-pack< 0000' "$wr_trace")
        wr_ready=$(grep -c 'upload-pack> ACK .* ready' "$wr_trace")
        if [ "$wr_haves" = 800 ] && [ "$wr_sent_haves" = 800 ] && [ "$wr_flushes" = 5 ] && [ "$wr_ready" = 1 ]; then
            note "wire fetch: git upload-pack saw all 800 haves in four flushed rounds (256+256+256+32) on one connection, and said ready after the last"
        else
            bad "wire fetch: negotiation as seen by git upload-pack" "output: $wr_out" "haves seen $wr_sent_haves, flushes $wr_flushes (want 5), ready lines $wr_ready"
        fi
        wr_new_commits=$(git -C "$wr_srv" rev-list --count main ^main~300)
        if [ "$wr_new_commits" = 300 ] && [ "$wr_pack_objects" -ge 900 ] && [ "$wr_pack_objects" -le 920 ]; then
            note "wire fetch: the pack holds only what the client lacked ($wr_pack_objects objects for 300 new commits; the 100 shared commits were not resent)"
        else
            bad "wire fetch: pack size" "pack objects $wr_pack_objects, new commits $wr_new_commits"
        fi
        if git -C "$wr_cli" index-pack --stdin --strict <"$wr_root/fetch.pack" >"$wr_root/fetch-index.log" 2>&1 &&
            git -C "$wr_cli" cat-file -e "$(git -C "$wr_srv" rev-parse main)^{commit}" &&
            git -C "$wr_cli" update-ref refs/remotes/origin/main "$(git -C "$wr_srv" rev-parse main)" &&
            git -C "$wr_cli" fsck --strict >"$wr_root/fetch-fsck.log" 2>&1; then
            note "wire fetch: git index-pack --strict accepts the pack, the server's tip is now present, git fsck --strict is clean"
        else
            bad "wire fetch: pack not accepted by git" "$(tail -5 "$wr_root/fetch-index.log")" "$(tail -5 "$wr_root/fetch-fsck.log" 2>/dev/null)"
        fi

        # --- clone: no haves at all, into a fresh repository ----------------
        wr_fresh="$wr_root/fresh.git"
        git init -q --bare -b main "$wr_fresh"
        wr_start upload-pack "$wr_srv"
        wr_out=$("$WORK/t_wire" fetch "$wr_port" "$wr_fresh" "$wr_root/clone.pack" 2>&1)
        "$WORK/t_wire" ls "$wr_port" git-upload-pack >"$wr_root/ls2.out" 2>&1
        wr_stop
        wr_clone_objects=$(printf '%s\n' "$wr_out" | sed -n 's/^pack [0-9]* //p')
        wr_all_objects=$(git -C "$wr_srv" rev-list --objects --all | wc -l | tr -d ' ')
        if git -C "$wr_fresh" index-pack --stdin --strict <"$wr_root/clone.pack" >"$wr_root/clone-index.log" 2>&1; then
            while IFS=$'\t' read -r wr_id wr_name; do
                case "$wr_name" in
                    refs/*'^{}') ;;
                    refs/*) git -C "$wr_fresh" update-ref "$wr_name" "$wr_id" ;;
                esac
            done <"$wr_root/ls2.out"
            if [ "$wr_clone_objects" -ge "$wr_all_objects" ] &&
                git -C "$wr_fresh" fsck --strict >"$wr_root/clone-fsck.log" 2>&1 &&
                [ "$(git -C "$wr_fresh" for-each-ref | md5sum)" = "$(git -C "$wr_srv" for-each-ref | md5sum)" ]; then
                note "wire clone: no haves, wants of every ref, $wr_clone_objects objects; index-pack --strict and fsck --strict clean, refs identical to the server's"
            else
                bad "wire clone" "objects $wr_clone_objects vs $wr_all_objects" "$(tail -5 "$wr_root/clone-fsck.log" 2>/dev/null)"
            fi
        else
            bad "wire clone: index-pack" "$(tail -5 "$wr_root/clone-index.log")" "$wr_out"
        fi

        # --- a server that is not there: hang-up, not a hang -----------------
        wr_start upload-pack "$wr_root/does-not-exist.git"
        wr_out=$("$WORK/t_wire" ls "$wr_port" git-upload-pack 2>&1)
        wr_stop
        case "$wr_out" in
            "error: advertisement: the connection ended"*) note "wire: a server that hangs up before advertising is Closed, not a hang" ;;
            *) bad "wire: hang-up before the advertisement" "$wr_out" ;;
        esac

        # --- push, over receive-pack -----------------------------------------
        wr_work="$wr_root/work"
        (
            set -e
            git init -q -b main "$wr_work"
            cd "$wr_work"
            git config user.name "Wire Test"
            git config user.email wire@example.com
            echo one >a.txt
            git add a.txt
            GIT_AUTHOR_DATE="1700000001 +0000" GIT_COMMITTER_DATE="1700000001 +0000" git commit -q -m one
            echo two >b.txt
            git add b.txt
            GIT_AUTHOR_DATE="1700000002 +0000" GIT_COMMITTER_DATE="1700000002 +0000" git commit -q -m two
        ) >"$wr_root/work.log" 2>&1 || bad "wire push fixture" "$(tail -5 "$wr_root/work.log")"

        wr_start receive-pack "$wr_empty"
        "$WORK/t_wire" ls "$wr_port" git-receive-pack >"$wr_root/rls.out" 2>&1
        if [ "$(grep -vc '^caps ' "$wr_root/rls.out")" = 0 ] && grep -q '^caps .*report-status' "$wr_root/rls.out"; then
            note "wire: an empty repository advertises no refs (capabilities^{} dropped) but its capabilities"
        else
            bad "wire: empty-repository advertisement" "$(cat "$wr_root/rls.out")"
        fi
        wr_zero=0000000000000000000000000000000000000000
        wr_out=$("$WORK/t_wire" push "$wr_port" "$wr_work/.git" refs/heads/main "$wr_zero" 2>&1)
        if [ "$wr_out" = "ok refs/heads/main" ] &&
            [ "$(git -C "$wr_empty" rev-parse refs/heads/main)" = "$(git -C "$wr_work" rev-parse main)" ] &&
            git -C "$wr_empty" fsck --strict >"$wr_root/push-fsck.log" 2>&1; then
            note "wire push: a first push to an empty repository is reported ok; the ref is the local tip and git fsck --strict is clean"
        else
            bad "wire push: first push" "$wr_out" "$(tail -5 "$wr_root/push-fsck.log" 2>/dev/null)"
        fi

        # A fast-forward: only the new commit's objects travel.
        wr_old=$(git -C "$wr_work" rev-parse main)
        (
            cd "$wr_work"
            echo three >c.txt
            git add c.txt
            GIT_AUTHOR_DATE="1700000003 +0000" GIT_COMMITTER_DATE="1700000003 +0000" git commit -q -m three
        ) >/dev/null 2>&1
        wr_out=$("$WORK/t_wire" push "$wr_port" "$wr_work/.git" refs/heads/main "$wr_old" 2>&1)
        if [ "$wr_out" = "ok refs/heads/main" ] &&
            [ "$(git -C "$wr_empty" rev-parse refs/heads/main)" = "$(git -C "$wr_work" rev-parse main)" ] &&
            git -C "$wr_empty" fsck --strict >"$wr_root/push2-fsck.log" 2>&1; then
            note "wire push: a fast-forward over the same kind of connection is ok and fsck --strict clean"
        else
            bad "wire push: fast-forward" "$wr_out" "$(tail -5 "$wr_root/push2-fsck.log" 2>/dev/null)"
        fi

        # A stale old id: the server says ng, the ref does not move.
        wr_before=$(git -C "$wr_empty" rev-parse refs/heads/main)
        (
            cd "$wr_work"
            echo four >d.txt
            git add d.txt
            GIT_AUTHOR_DATE="1700000004 +0000" GIT_COMMITTER_DATE="1700000004 +0000" git commit -q -m four
        ) >/dev/null 2>&1
        wr_out=$("$WORK/t_wire" push "$wr_port" "$wr_work/.git" refs/heads/main "$(git -C "$wr_work" rev-parse main~2)" 2>&1)
        wr_status=$?
        wr_stale_ok=0
        case "$wr_out" in "ng refs/heads/main "*) wr_stale_ok=1 ;; esac
        if [ "$wr_stale_ok" = 1 ] && [ "$wr_status" -ne 0 ] && [ "$(git -C "$wr_empty" rev-parse refs/heads/main)" = "$wr_before" ]; then
            note "wire push: a push against a stale old id is reported 'ng' with the server's reason ($wr_out) and the ref does not move"
        else
            bad "wire push: stale old id" "status $wr_status: $wr_out"
        fi
        wr_stop
        unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE
    else
        note "wire: python3 not found; the real-git checks were skipped"
    fi
else
    :
fi
