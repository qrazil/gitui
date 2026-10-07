# `packwrite.m31`, `httppush.m31` and `gitconfig.m31`, against real git as the
# oracle: `git index-pack --strict` judges every pack this writes, and a real
# `git http-backend` (the same CGI-behind-python arrangement `test_httpfetch.sh`
# uses, but with `http.receivepack` on) is the server a push goes to -- the
# server's own refs and `git fsck --full` are what say the push worked. Nothing
# here touches a real remote, and the only credentials anywhere in this file
# are the throwaway fixture pair below.
#
# Sourced from `test.sh`, sharing its shell, `$WORK`, `build`, `note`/`bad`
# and the counters. Like `test_httpfetch.sh` it starts background servers, so
# it rewrites the EXIT trap once more -- killing its own PIDs as well as
# whatever `test_httpfetch.sh` left to kill, then `test.sh`'s own `rm -rf`.

pp_root="$WORK/push"
mkdir -p "$pp_root"

# --- fixture: a client repository with real history ---------------------------

pp_cl="$pp_root/client"
(
    set -e
    mkdir -p "$pp_cl"
    cd "$pp_cl"
    git init -q -b main .
    git config user.email push@example.com
    git config user.name "Push Tester"
    i=1
    while [ "$i" -le 5 ]; do
        printf 'line %d\nshared text that repeats between commits\n' "$i" >>big.txt
        mkdir -p dir/sub
        echo "content $i" >"dir/sub/f$i.txt"
        git add -A
        GIT_AUTHOR_DATE="171000000$i +0000" GIT_COMMITTER_DATE="171000000$i +0000" git commit -q -m "commit $i"
        i=$((i + 1))
    done
    git tag -a v1 -m "annotated" main~2
) >"$WORK/push-fixture.log" 2>&1 && note "push: client fixture built (5 commits, nested trees, an annotated tag)" ||
    bad "push client fixture" "$(tail -8 "$WORK/push-fixture.log")"

pp_gd="$pp_cl/.git"
pp_tip=$(git -C "$pp_cl" rev-parse main)

# --- packwrite: entry headers, then packs judged by real index-pack -----------

if build t_packwrite; then
    pp_hdr_ok=1
    # type 3 (blob) size 5 -> one byte 0x35; type 1 size 16 -> 0x90 0x01;
    # type 2 size 300 -> 0xac 0x12; type 3 size 0 -> 0x30.
    for pp_case in "3 5 35" "1 16 9001" "2 300 ac12" "3 0 30"; do
        set -- $pp_case
        got=$("$WORK/t_packwrite" header "$1" "$2" 2>&1)
        [ "$got" = "$3" ] || { pp_hdr_ok=0; note "header $1 $2: got '$got' want '$3'"; }
    done
    if [ "$pp_hdr_ok" = 1 ]; then
        note "packwrite: entry headers (type/size varints) match the pack format's own definition"
    else
        bad "packwrite entry headers" "see notes above"
    fi

    pp_idx="$pp_root/idx.git"
    git init -q --bare "$pp_idx"
    pp_pack="$pp_root/all.pack"
    if "$WORK/t_packwrite" build "$pp_gd" "$pp_pack" >"$WORK/push-build.out" 2>"$WORK/push-build.err"; then
        if git -C "$pp_idx" index-pack --strict --stdin <"$pp_pack" >"$WORK/push-idx.out" 2>"$WORK/push-idx.err"; then
            pp_want=$(git -C "$pp_cl" count-objects -v | awk '/^count:/ {a=$2} /^in-pack:/ {b=$2} END {print a+b}')
            pp_got=$(git -C "$pp_idx" count-objects -v | awk '/^in-pack:/ {print $2}')
            if [ "$pp_got" = "$pp_want" ]; then
                note "packwrite: real 'git index-pack --strict' accepts a pack of every object ($pp_got objects)"
            else
                bad "packwrite object count" "index-pack indexed $pp_got, repository has $pp_want"
            fi
            # Round trip through pack.m31's own reader.
            pp_rt_ok=1
            pp_checked=0
            for id in $(git -C "$pp_cl" cat-file --batch-all-objects --batch-check='%(objectname)'); do
                want="$(git -C "$pp_cl" cat-file -t "$id") $(git -C "$pp_cl" cat-file -s "$id")"
                got=$("$WORK/t_packwrite" stat "$pp_idx" "$id" 2>&1)
                [ "$got" = "$want" ] || { pp_rt_ok=0; note "stat $id: got '$got' want '$want'"; }
                pp_checked=$((pp_checked + 1))
            done
            if [ "$pp_rt_ok" = 1 ]; then
                note "packwrite: all $pp_checked objects read back through pack.m31 with the right kind, size and SHA-1"
            else
                bad "packwrite round trip through pack.m31" "see notes above"
            fi
        else
            bad "packwrite: index-pack --strict" "$(cat "$WORK/push-idx.err")"
        fi
    else
        bad "packwrite build" "$(cat "$WORK/push-build.err")"
    fi
fi

# --- the config reader and URL parsing, no server ------------------------------

if build t_push; then
    cat >"$pp_root/cfg" <<'CFG'
# a comment
[core]
	bare = false
[remote "origin"]
	url = http://example.test/a.git
	fetch = +refs/heads/*:refs/remotes/origin/*
	pushurl = http://example.test/p.git # trailing note
[Remote "origin"]
	URL = "http://example.test/quoted \"x\".git"
[remote "other"] ; trailing comment
	url = http://other.test/b.git
[branch.main]
	remote = origin
CFG
    pp_cfg_ok=1
    chk() {
        got=$("$WORK/t_push" config "$pp_root/cfg" "$1" "$2" "$3" 2>&1)
        [ "$got" = "$4" ] || { pp_cfg_ok=0; note "config $1 $2 $3: got '$got' want '$4'"; }
    }
    chk remote other url "http://other.test/b.git"
    chk remote origin fetch "+refs/heads/*:refs/remotes/origin/*"
    chk remote origin url 'http://example.test/quoted "x".git'
    chk remote origin pushurl http://example.test/p.git
    chk core "" bare false
    chk branch main remote origin
    chk remote nosuch url none
    chk remote origin missing none
    if [ "$pp_cfg_ok" = 1 ]; then
        note "gitconfig: sections, subsections (both spellings), quoting, comments and last-wins all read like git"
    else
        bad "gitconfig reader" "see notes above"
    fi
    # And against git's own idea of the same repository.
    git -C "$pp_cl" remote add origin http://example.test/real.git
    got=$("$WORK/t_push" origin "$pp_gd" 2>&1)
    want=$(git -C "$pp_cl" config remote.origin.url)
    if [ "$got" = "$want" ]; then
        note "gitconfig: remote.origin.url from a real .git/config equals 'git config'"
    else
        bad "gitconfig vs git config" "got '$got' want '$want'"
    fi
    git -C "$pp_cl" remote remove origin

    pp_url_ok=1
    got=$("$WORK/t_push" remote "http://alice:hunter2@host:8080/r.git" 2>&1)
    [ "$got" = "url http://host:8080/r.git
user alice" ] || { pp_url_ok=0; note "remote userinfo: got '$got'"; }
    case "$got" in *hunter2*) pp_url_ok=0 ;; esac
    got=$("$WORK/t_push" remote "http://host/r.git" 2>&1)
    [ "$got" = "url http://host/r.git
user -" ] || { pp_url_ok=0; note "remote plain: got '$got'"; }
    if "$WORK/t_push" remote "https://host/r.git" >/dev/null 2>&1; then pp_url_ok=0; fi
    if "$WORK/t_push" remote "/some/path" >/dev/null 2>&1; then pp_url_ok=0; fi
    if [ "$pp_url_ok" = 1 ]; then
        note "httppush: userinfo is split out (password never printed); https:// and local paths are refused"
    else
        bad "httppush parse_remote" "see notes above"
    fi

    # parse_report: pkt-lines built by a script, so the lengths are right.
    pkt() { python3 -c 'import sys; s=sys.argv[1].encode().decode("unicode_escape").encode(); sys.stdout.buffer.write(b"%04x" % (len(s)+4) + s)' "$1"; }
    {
        pkt 'unpack ok\n'
        pkt 'ok refs/heads/main\n'
        printf '0000'
    } >"$pp_root/rep-ok"
    {
        pkt 'unpack ok\n'
        pkt 'ng refs/heads/main hook declined\n'
        printf '0000'
    } >"$pp_root/rep-ng"
    {
        pkt 'unpack index-pack abnormal exit\n'
        pkt 'ng refs/heads/main unpacker error\n'
        printf '0000'
    } >"$pp_root/rep-unpack"
    printf '0010unpack ok\n0000' >"$pp_root/rep-noref"
    printf 'garbage' >"$pp_root/rep-bad"
    pp_rep_ok=1
    got=$("$WORK/t_push" report "$pp_root/rep-ok" refs/heads/main 2>&1)
    [ "$got" = "unpacked true ok true reason " ] || { pp_rep_ok=0; note "report ok: '$got'"; }
    got=$("$WORK/t_push" report "$pp_root/rep-ng" refs/heads/main 2>&1)
    [ "$got" = "unpacked true ok false reason hook declined" ] || { pp_rep_ok=0; note "report ng: '$got'"; }
    got=$("$WORK/t_push" report "$pp_root/rep-unpack" refs/heads/main 2>&1)
    case "$got" in "unpacked false ok false"*) ;; *) pp_rep_ok=0; note "report unpack: '$got'" ;; esac
    "$WORK/t_push" report "$pp_root/rep-noref" refs/heads/main >/dev/null 2>&1 && { pp_rep_ok=0; note "report without the ref was accepted"; }
    "$WORK/t_push" report "$pp_root/rep-bad" refs/heads/main >/dev/null 2>&1 && { pp_rep_ok=0; note "garbage report was accepted"; }
    if [ "$pp_rep_ok" = 1 ]; then
        note "httppush: report-status parsing -- ok, ng with reason, unpack failure, missing ref and garbage"
    else
        bad "httppush parse_report" "see notes above"
    fi

    # --- the object set a push sends equals git rev-list --objects ---------
    pp_prev=$(git -C "$pp_cl" rev-parse main~2)
    "$WORK/t_push" objects "$pp_gd" "$pp_tip" "$pp_prev" >"$WORK/push-objs.got" 2>"$WORK/push-objs.err"
    git -C "$pp_cl" rev-list --objects "$pp_tip" "^$pp_prev" | awk '{print $1}' | sort >"$WORK/push-objs.want"
    if cmp -s "$WORK/push-objs.got" "$WORK/push-objs.want" && [ -s "$WORK/push-objs.want" ]; then
        note "packwrite: the object set for an incremental push equals 'git rev-list --objects tip ^known' ($(wc -l <"$WORK/push-objs.want") objects)"
    else
        bad "packwrite object set" "$(diff "$WORK/push-objs.got" "$WORK/push-objs.want" | head -8)" "$(cat "$WORK/push-objs.err")"
    fi

    pp_anc=$("$WORK/t_push" ancestor "$pp_gd" "$pp_prev" "$pp_tip")
    pp_nanc=$("$WORK/t_push" ancestor "$pp_gd" "$pp_tip" "$pp_prev")
    if [ "$pp_anc $pp_nanc" = "yes no" ]; then
        note "httppush: is_ancestor agrees with the history's direction"
    else
        bad "httppush is_ancestor" "$pp_anc $pp_nanc"
    fi
fi

# --- real servers: git http-backend, one open, one wanting Basic auth ----------

pp_backend="$(git --exec-path)/git-http-backend"
if command -v python3 >/dev/null 2>&1 && [ -x "$pp_backend" ] && [ -x "$WORK/t_push" ]; then
    mkdir -p "$pp_root/srv" "$pp_root/srva" "$pp_root/www/cgi-bin"
    for pp_dir in srv srva; do
        git init -q --bare -b main "$pp_root/$pp_dir/repo.git"
        git -C "$pp_root/$pp_dir/repo.git" config http.receivepack true
    done
    # A server-side policy only the oracle can enforce: refs/heads/blocked is refused.
    cat >"$pp_root/srv/repo.git/hooks/pre-receive" <<'HOOK'
#!/bin/sh
while read old new ref; do
    [ "$ref" = refs/heads/blocked ] && { echo "blocked by policy" >&2; exit 1; }
done
exit 0
HOOK
    chmod +x "$pp_root/srv/repo.git/hooks/pre-receive"

    for pp_dir in srv srva; do
        cat >"$pp_root/www/cgi-bin/git-http-backend-$pp_dir" <<WRAP
#!/bin/sh
export GIT_PROJECT_ROOT="$pp_root/$pp_dir"
export GIT_HTTP_EXPORT_ALL=1
exec "$pp_backend"
WRAP
        chmod +x "$pp_root/www/cgi-bin/git-http-backend-$pp_dir"
    done

    cat >"$pp_root/serve.py" <<'PY'
import base64
import http.server
import os
import sys

port = int(sys.argv[1])
os.chdir(sys.argv[2])
want = os.environ.get("PUSH_TEST_AUTH")


class Handler(http.server.CGIHTTPRequestHandler):
    cgi_directories = ["/cgi-bin"]

    def log_message(self, fmt, *args):
        pass

    def allowed(self):
        if not want:
            return True
        got = self.headers.get("Authorization", "")
        return got == "Basic " + base64.b64encode(want.encode()).decode()

    def deny(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="t"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if self.allowed():
            super().do_GET()
        else:
            self.deny()

    def do_POST(self):
        if self.allowed():
            super().do_POST()
        else:
            self.deny()


http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY

    pp_port=$((20000 + (RANDOM % 20000)))
    pp_aport=$((pp_port + 1))
    python3 "$pp_root/serve.py" "$pp_port" "$pp_root/www" >"$WORK/push-server.log" 2>&1 &
    pp_server_pid=$!
    PUSH_TEST_AUTH="pusher:fixture-pw" python3 "$pp_root/serve.py" "$pp_aport" "$pp_root/www" >"$WORK/push-aserver.log" 2>&1 &
    pp_aserver_pid=$!
    trap 'kill ${hf_server_pid:+"$hf_server_pid"} ${hf_proxy_pid:+"$hf_proxy_pid"} "$pp_server_pid" "$pp_aserver_pid" >/dev/null 2>&1; wait ${hf_server_pid:+"$hf_server_pid"} ${hf_proxy_pid:+"$hf_proxy_pid"} "$pp_server_pid" "$pp_aserver_pid" 2>/dev/null; rm -rf "$WORK"' EXIT

    pp_up=0
    for pp_try in $(seq 1 50); do
        if (exec 3<>"/dev/tcp/127.0.0.1/$pp_port") 2>/dev/null && (exec 4<>"/dev/tcp/127.0.0.1/$pp_aport") 2>/dev/null; then
            pp_up=1
            break
        fi
        sleep 0.1
    done

    pp_url="http://127.0.0.1:$pp_port/cgi-bin/git-http-backend-srv/repo.git"
    pp_aurl="http://127.0.0.1:$pp_aport/cgi-bin/git-http-backend-srva/repo.git"
    pp_srv="$pp_root/srv/repo.git"
    pp_asrv="$pp_root/srva/repo.git"

    if [ "$pp_up" = 1 ]; then
        # --- A: first push, to an empty server -----------------------------
        if "$WORK/t_push" push "$pp_gd" "$pp_url" refs/heads/main >"$WORK/push-a.out" 2>"$WORK/push-a.err" &&
            [ "$(git -C "$pp_srv" rev-parse refs/heads/main)" = "$pp_tip" ] &&
            git -C "$pp_srv" fsck --full >"$WORK/push-a.fsck" 2>&1; then
            note "push: first push to an empty server created refs/heads/main at the client's tip; server 'git fsck --full' is clean"
        else
            bad "push to an empty server" "$(cat "$WORK/push-a.out")" "$(cat "$WORK/push-a.err")" "$(cat "$WORK/push-a.fsck" 2>/dev/null)"
        fi

        # --- B: new commits -------------------------------------------------
        (
            cd "$pp_cl"
            echo "more" >>big.txt
            echo "new file" >dir/new.txt
            git add -A
            GIT_AUTHOR_DATE="1710000100 +0000" GIT_COMMITTER_DATE="1710000100 +0000" git commit -q -m "commit 6"
        ) >/dev/null 2>&1
        pp_tip2=$(git -C "$pp_cl" rev-parse main)
        if "$WORK/t_push" push "$pp_gd" "$pp_url" refs/heads/main >"$WORK/push-b.out" 2>"$WORK/push-b.err" &&
            [ "$(git -C "$pp_srv" rev-parse refs/heads/main)" = "$pp_tip2" ] &&
            git -C "$pp_srv" fsck --full >"$WORK/push-b.fsck" 2>&1; then
            git -C "$pp_cl" rev-list --objects main | awk '{print $1}' | sort >"$WORK/push-b.ids"
            git -C "$pp_cl" cat-file --batch <"$WORK/push-b.ids" >"$WORK/push-b.client"
            git -C "$pp_srv" cat-file --batch <"$WORK/push-b.ids" >"$WORK/push-b.server"
            if cmp -s "$WORK/push-b.client" "$WORK/push-b.server"; then
                note "push: new commits moved the server's ref; fsck clean; all $(wc -l <"$WORK/push-b.ids") reachable objects byte-identical on both sides"
            else
                bad "push B: object bytes differ between client and server"
            fi
        else
            bad "push of new commits" "$(cat "$WORK/push-b.out")" "$(cat "$WORK/push-b.err")" "$(cat "$WORK/push-b.fsck" 2>/dev/null)"
        fi

        # --- C: a brand-new branch -----------------------------------------
        git -C "$pp_cl" branch feature main~1
        (cd "$pp_cl" && git checkout -q feature && echo f >feature.txt && git add -A &&
            GIT_AUTHOR_DATE="1710000200 +0000" GIT_COMMITTER_DATE="1710000200 +0000" git commit -q -m "on feature" &&
            git checkout -q main) >/dev/null 2>&1
        pp_ftip=$(git -C "$pp_cl" rev-parse feature)
        if "$WORK/t_push" push "$pp_gd" "$pp_url" refs/heads/feature >"$WORK/push-c.out" 2>"$WORK/push-c.err" &&
            [ "$(git -C "$pp_srv" rev-parse refs/heads/feature)" = "$pp_ftip" ] &&
            [ "$(git -C "$pp_srv" rev-parse refs/heads/main)" = "$pp_tip2" ] &&
            git -C "$pp_srv" fsck --full >/dev/null 2>&1; then
            note "push: a brand-new branch is created on the server, main untouched, fsck clean"
        else
            bad "push of a new branch" "$(cat "$WORK/push-c.out")" "$(cat "$WORK/push-c.err")"
        fi

        # --- D: nothing to do ----------------------------------------------
        if ! "$WORK/t_push" push "$pp_gd" "$pp_url" refs/heads/main >"$WORK/push-d.out" 2>"$WORK/push-d.err" &&
            grep -q "up to date" "$WORK/push-d.err"; then
            note "push: pushing an unchanged branch reports 'everything up to date' and sends nothing"
        else
            bad "push up to date" "$(cat "$WORK/push-d.out")" "$(cat "$WORK/push-d.err")"
        fi

        # --- E: someone else advances the server; we must not clobber it ----
        pp_other="$pp_root/other"
        git clone -q "$pp_url" "$pp_other" >/dev/null 2>&1
        (cd "$pp_other" && git config user.email o@example.com && git config user.name Other &&
            echo theirs >theirs.txt && git add -A &&
            GIT_AUTHOR_DATE="1710000300 +0000" GIT_COMMITTER_DATE="1710000300 +0000" git commit -q -m "theirs" &&
            git push -q origin main) >"$WORK/push-e.log" 2>&1
        pp_theirs=$(git -C "$pp_srv" rev-parse refs/heads/main)
        (cd "$pp_cl" && echo mine >mine.txt && git add -A &&
            GIT_AUTHOR_DATE="1710000400 +0000" GIT_COMMITTER_DATE="1710000400 +0000" git commit -q -m "mine") >/dev/null 2>&1
        if [ "$pp_theirs" != "$pp_tip2" ] && ! "$WORK/t_push" push "$pp_gd" "$pp_url" refs/heads/main >"$WORK/push-e.out" 2>"$WORK/push-e.err" &&
            grep -q "fetch first" "$WORK/push-e.err" &&
            [ "$(git -C "$pp_srv" rev-parse refs/heads/main)" = "$pp_theirs" ]; then
            note "push: remote tip this repository has never seen is refused ('fetch first'); the server's ref is unchanged"
        else
            bad "push when behind" "$(cat "$WORK/push-e.out")" "$(cat "$WORK/push-e.err")" "$(cat "$WORK/push-e.log")"
        fi
        # Now teach the client that commit (a real fetch), so the remote tip
        # is known but still not an ancestor: the genuine non-fast-forward.
        git -C "$pp_cl" fetch -q "$pp_url" main >/dev/null 2>&1
        if ! "$WORK/t_push" push "$pp_gd" "$pp_url" refs/heads/main >"$WORK/push-e2.out" 2>"$WORK/push-e2.err" &&
            grep -q "not a fast-forward" "$WORK/push-e2.err" &&
            [ "$(git -C "$pp_srv" rev-parse refs/heads/main)" = "$pp_theirs" ] &&
            git -C "$pp_srv" fsck --full >/dev/null 2>&1; then
            note "push: a diverged branch is refused as 'not a fast-forward'; nothing sent, server unchanged"
        else
            bad "push non-fast-forward" "$(cat "$WORK/push-e2.out")" "$(cat "$WORK/push-e2.err")"
        fi

        # --- F: the server itself says no (pre-receive hook) ----------------
        git -C "$pp_cl" branch blocked "$pp_ftip"
        got=$("$WORK/t_push" push "$pp_gd" "$pp_url" refs/heads/blocked 2>&1)
        case "$got" in
            "ng refs/heads/blocked "*)
                if ! git -C "$pp_srv" rev-parse -q --verify refs/heads/blocked >/dev/null; then
                    note "push: a server-side refusal is reported with its ng line ($got) and no ref was created"
                else
                    bad "push refused by hook" "the ref exists on the server anyway"
                fi
                ;;
            *) bad "push refused by hook" "$got" ;;
        esac

        # --- G: authentication -----------------------------------------------
        got=$("$WORK/t_push" push "$pp_gd" "$pp_aurl" refs/heads/feature 2>&1)
        if [ $? -ne 0 ] && ! git -C "$pp_asrv" rev-parse -q --verify refs/heads/feature >/dev/null; then
            case "$got" in
                *credentials*) note "push: a 401 without credentials is reported as an auth failure; nothing created" ;;
                *) bad "push auth failure message" "$got" ;;
            esac
        else
            bad "push without credentials to an authenticated server" "$got"
        fi
        pp_auth_url="http://pusher:fixture-pw@127.0.0.1:$pp_aport/cgi-bin/git-http-backend-srva/repo.git"
        got=$("$WORK/t_push" push "$pp_gd" "$pp_auth_url" refs/heads/feature 2>&1)
        if [ "$(git -C "$pp_asrv" rev-parse refs/heads/feature 2>/dev/null)" = "$pp_ftip" ]; then
            case "$got" in
                *fixture-pw*) bad "push leaked the password" "$got" ;;
                *) note "push: credentials from the URL's userinfo authenticate; the password appears nowhere in the output" ;;
            esac
        else
            bad "push with URL credentials" "$got"
        fi
        got=$(GITUI_HTTP_USER=pusher GITUI_HTTP_PASSWORD=fixture-pw "$WORK/t_push" push "$pp_gd" "$pp_aurl" refs/heads/main 2>&1)
        if git -C "$pp_asrv" rev-parse -q --verify refs/heads/main >/dev/null &&
            git -C "$pp_asrv" fsck --full >/dev/null 2>&1; then
            note "push: GITUI_HTTP_USER/GITUI_HTTP_PASSWORD authenticate when the URL carries none"
        else
            bad "push with env credentials" "$got"
        fi
        got=$("$WORK/t_push" push "$pp_gd" "http://pusher:wrong@127.0.0.1:$pp_aport/cgi-bin/git-http-backend-srva/repo.git" refs/heads/blocked 2>&1)
        case "$got" in
            *credentials*) note "push: wrong credentials are reported as an auth failure" ;;
            *) bad "push wrong credentials" "$got" ;;
        esac
    else
        bad "push servers did not come up" "$(cat "$WORK/push-server.log")"
    fi
else
    note "push: python3 or git-http-backend missing; server-backed checks skipped"
fi
