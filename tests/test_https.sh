# smart HTTP over TLS: fetch, push and pull against `https://` remotes.
#
# Sourced from `test.sh` after `test_pull.sh`, sharing its shell, `$WORK`,
# `build`, `note`/`bad` and the counters. It starts three servers of its own
# (`tests/https_serve.py`: real `git http-backend` behind Python's `ssl`, TLS
# 1.3, with a plain-HTTP listener beside each) and so, like the other server
# scripts, rewrites the EXIT trap -- killing every server any sourced script
# started, by exact PID, before `test.sh`'s own `rm -rf "$WORK"`.
#
# There is no insecure mode in the standard library's TLS, so nothing here
# switches verification off. The test CA is supplied the one way a user
# would supply a private CA: `GITUI_HTTP_CA_FILE=<ca.pem>` (see
# `GIT_http_fetch.trust`), which becomes `tls.Trust.CaFile`. The server's
# certificate is for `localhost`, issued by that CA, made with `openssl`.
#
#   fetch    `ls-remote`, a full clone and a fetch with `have`s over https,
#            judged by real git (`git ls-remote`, `git index-pack`)
#   push     to an https server wanting HTTP Basic auth: credentials from the
#            URL and from the environment; none, wrong, and the password
#            never printed
#   pull     a fast-forward over https, with auth
#   trust    an unknown CA, another CA's file, a certificate for another
#            host, and a CA file that is not there are all refused, and
#            nothing is written or moved
#   redirect a same-origin 307 is followed (GET and POST, credentials kept);
#            `http` to `https` on the same host is followed; `https` to
#            `http` is refused
#   http     the same server's plain listener still works with no CA at all

hs_root="$WORK/https"
mkdir -p "$hs_root"
hs_pids=()

hs_wait_ready() {
    # hs_wait_ready <log> -> sets hs_tls_port hs_plain_port; fails if never up
    local tries=0
    while [ "$tries" -lt 100 ]; do
        if grep -q '^ready ' "$1" 2>/dev/null; then
            read -r _ hs_tls_port hs_plain_port <"$1"
            return 0
        fi
        sleep 0.1
        tries=$((tries + 1))
    done
    return 1
}

hs_serve() {
    # hs_serve <name> <repos dir> <cert> <key> [user:password]: starts a
    # server, sets hs_tls_port / hs_plain_port.
    python3 tests/https_serve.py "$2" "$3" "$4" ${5:+"$5"} >"$hs_root/$1.log" 2>"$hs_root/$1.err" </dev/null &
    hs_pids+=("$!")
    hs_wait_ready "$hs_root/$1.log"
}

hs_reap() {
    local pid
    for pid in ${hs_pids[@]+"${hs_pids[@]}"}; do
        kill "$pid" >/dev/null 2>&1
        wait "$pid" 2>/dev/null
    done
}
trap 'hs_reap; for pid in ${hf_server_pid:-} ${hf_proxy_pid:-} ${pp_server_pid:-} ${pp_aserver_pid:-}; do kill "$pid" >/dev/null 2>&1; wait "$pid" 2>/dev/null; done; rm -rf "$WORK"' EXIT

# --- certificates --------------------------------------------------------------

hs_certs="$hs_root/certs"
mkdir -p "$hs_certs"
hs_have_certs=0
if command -v openssl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 &&
    [ -x "$(git --exec-path)/git-http-backend" ]; then
    (
        set -e
        cd "$hs_certs"
        mkca() {
            openssl ecparam -name prime256v1 -genkey -noout -out "$1.key"
            openssl req -x509 -new -key "$1.key" -sha256 -days 30 -subj "/CN=$1" \
                -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign \
                -out "$1.pem"
        }
        mkleaf() {
            # mkleaf <stem> <ca> <dns name>
            openssl ecparam -name prime256v1 -genkey -noout -out "$1.key"
            openssl req -new -key "$1.key" -subj "/CN=$3" -out "$1.csr"
            printf 'subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\nkeyUsage=digitalSignature\n' "$3" >"$1.ext"
            openssl x509 -req -in "$1.csr" -CA "$2.pem" -CAkey "$2.key" -CAcreateserial -days 30 -sha256 \
                -extfile "$1.ext" -out "$1.pem"
        }
        mkca test-ca
        mkca other-ca
        mkleaf localhost test-ca localhost
        mkleaf wronghost test-ca other.test
    ) >"$hs_root/certs.log" 2>&1 && hs_have_certs=1 && note "https: test CA and leaf certificates made (localhost, and one for another host)"
    [ "$hs_have_certs" = 1 ] || bad "https certificates" "$(tail -5 "$hs_root/certs.log")"
else
    note "https: openssl, python3 or git-http-backend missing; https checks skipped"
fi

if [ "$hs_have_certs" = 1 ]; then
    build t_httpfetch
    [ -x "$WORK/t_push" ] || build t_push
    [ -x "$WORK/t_pull" ] || build t_pull
fi

if [ "$hs_have_certs" = 1 ] && [ -x "$WORK/t_httpfetch" ] && [ -x "$WORK/t_push" ] && [ -x "$WORK/t_pull" ]; then
    hs_ca="$hs_certs/test-ca.pem"

    # --- fixtures: a source history, an open bare repo, an empty one for push ---

    hs_src="$hs_root/src"
    (
        set -e
        mkdir -p "$hs_src"
        cd "$hs_src"
        git init -q -b main .
        git config user.email https@example.com
        git config user.name "HTTPS Tester"
        i=1
        while [ "$i" -le 6 ]; do
            seq 1 200 | sed 's/$/ common line/' >big.txt
            echo "revision $i" >>big.txt
            echo "content $i" >"file$i.txt"
            git add -A
            GIT_AUTHOR_DATE="173000000$i +0000" GIT_COMMITTER_DATE="173000000$i +0000" git commit -q -m "commit $i"
            i=$((i + 1))
        done
        git tag -a v1 -m "release 1" main~2
    ) >"$hs_root/src.log" 2>&1 && note "https: source fixture built (6 commits, an annotated tag)" || bad "https source fixture" "$(tail -5 "$hs_root/src.log")"

    mkdir -p "$hs_root/open" "$hs_root/auth"
    git clone -q --bare "$hs_src" "$hs_root/open/repo.git" >/dev/null 2>&1
    git -C "$hs_root/open/repo.git" config http.receivepack true
    git -C "$hs_root/open/repo.git" gc -q >/dev/null 2>&1
    git init -q --bare -b main "$hs_root/auth/repo.git"
    git -C "$hs_root/auth/repo.git" config http.receivepack true

    hs_up=1
    hs_serve open "$hs_root/open" "$hs_certs/localhost.pem" "$hs_certs/localhost.key" || hs_up=0
    hs_otls=$hs_tls_port
    hs_oplain=$hs_plain_port
    hs_serve auth "$hs_root/auth" "$hs_certs/localhost.pem" "$hs_certs/localhost.key" "pusher:fixture-pw" || hs_up=0
    hs_atls=$hs_tls_port
    hs_aplain=$hs_plain_port
    hs_serve wrong "$hs_root/open" "$hs_certs/wronghost.pem" "$hs_certs/wronghost.key" || hs_up=0
    hs_wtls=$hs_tls_port

    if [ "$hs_up" = 1 ]; then
        note "https: three servers up (open, Basic-auth, and one with a certificate for another host)"

        hs_url="https://localhost:$hs_otls/git/repo.git"
        hs_aurl="https://localhost:$hs_atls/git/repo.git"
        hs_srv="$hs_root/open/repo.git"
        hs_asrv="$hs_root/auth/repo.git"
        hs_cred="https://pusher:fixture-pw@localhost:$hs_atls/git/repo.git"
        # The client under test trusts the test CA only through this variable.
        hs_with_ca() { GITUI_HTTP_CA_FILE="$hs_ca" "$@"; }

        # --- the oracle itself: real git over the same TLS server ------------------

        if GIT_SSL_CAINFO="$hs_ca" git ls-remote "$hs_url" >"$hs_root/ls.want" 2>"$hs_root/ls.werr"; then
            note "https: real git ls-remote reaches the server over TLS (the oracle works)"
        else
            bad "https oracle" "$(head -3 "$hs_root/ls.werr")"
        fi

        # --- fetch -----------------------------------------------------------------

        if hs_with_ca "$WORK/t_httpfetch" ls-remote "$hs_url" >"$hs_root/ls.got" 2>"$hs_root/ls.err" &&
            cmp -s "$hs_root/ls.got" "$hs_root/ls.want"; then
            note "https fetch: the ref advertisement over TLS matches 'git ls-remote' byte for byte"
        else
            bad "https ls-remote" "$(diff "$hs_root/ls.got" "$hs_root/ls.want" | head -6)" "$(head -3 "$hs_root/ls.err")"
        fi

        hs_pack="$hs_root/clone.pack"
        hs_objs=$(git -C "$hs_srv" rev-list --objects --all | wc -l | tr -d ' ')
        if hs_with_ca "$WORK/t_httpfetch" clone "$hs_url" "$hs_pack" >"$hs_root/clone.out" 2>"$hs_root/clone.err"; then
            rm -rf "$hs_root/idx1"
            git init -q --bare "$hs_root/idx1"
            if git -C "$hs_root/idx1" index-pack --stdin <"$hs_pack" >/dev/null 2>"$hs_root/idx1.err" &&
                grep -q "^pack [0-9]* $hs_objs\$" "$hs_root/clone.out"; then
                note "https fetch: a full clone over TLS is a verified pack of $hs_objs objects and real 'git index-pack' accepts it"
            else
                bad "https clone: index-pack" "$(cat "$hs_root/clone.out")" "$(cat "$hs_root/idx1.err")"
            fi
        else
            bad "https clone" "$(cat "$hs_root/clone.out")" "$(cat "$hs_root/clone.err")"
        fi

        # A repository that has the history already (cloned by real git over
        # https), then the server gains a commit: negotiation must shrink the pack.
        git -c http.sslCAInfo="$hs_ca" clone -q "$hs_url" "$hs_root/local" >/dev/null 2>&1
        (
            cd "$hs_src"
            echo "after the clone" >late.txt
            git add -A
            GIT_AUTHOR_DATE="1730000100 +0000" GIT_COMMITTER_DATE="1730000100 +0000" git commit -q -m "late commit"
            git push -q "$hs_srv" main
        ) >/dev/null 2>&1
        git -C "$hs_srv" gc -q >/dev/null 2>&1
        if hs_with_ca "$WORK/t_httpfetch" fetch "$hs_url" "$hs_root/local/.git" "$hs_root/fetch.pack" >"$hs_root/fetch.out" 2>"$hs_root/fetch.err" &&
            [ "$(wc -c <"$hs_root/fetch.pack")" -lt "$(wc -c <"$hs_pack")" ] &&
            git -C "$hs_root/local" index-pack --stdin <"$hs_root/fetch.pack" >/dev/null 2>&1; then
            note "https fetch: with haves the pack shrinks ($(wc -c <"$hs_pack") -> $(wc -c <"$hs_root/fetch.pack") bytes) and real index-pack accepts it"
        else
            bad "https fetch with haves" "$(cat "$hs_root/fetch.out")" "$(cat "$hs_root/fetch.err")"
        fi

        # --- trust: refused, with nothing written ----------------------------------

        rm -f "$hs_root/refused.pack"
        env -u GITUI_HTTP_CA_FILE "$WORK/t_httpfetch" clone "$hs_url" "$hs_root/refused.pack" >/dev/null 2>"$hs_root/untrusted.err"
        hs_status=$?
        if [ "$hs_status" -ne 0 ] && [ ! -e "$hs_root/refused.pack" ] && grep -q "certificate was refused" "$hs_root/untrusted.err"; then
            note "https trust: a certificate from a CA the system does not trust is refused, nothing written"
        else
            bad "https untrusted certificate" "status $hs_status" "$(head -3 "$hs_root/untrusted.err")"
        fi

        GITUI_HTTP_CA_FILE="$hs_certs/other-ca.pem" "$WORK/t_httpfetch" clone "$hs_url" "$hs_root/refused.pack" >/dev/null 2>"$hs_root/otherca.err"
        hs_status=$?
        if [ "$hs_status" -ne 0 ] && [ ! -e "$hs_root/refused.pack" ] && grep -q "certificate was refused" "$hs_root/otherca.err"; then
            note "https trust: a CA file that does not hold the issuer refuses the certificate"
        else
            bad "https wrong CA file" "status $hs_status" "$(head -3 "$hs_root/otherca.err")"
        fi

        GITUI_HTTP_CA_FILE="$hs_certs/no-such-file.pem" "$WORK/t_httpfetch" clone "$hs_url" "$hs_root/refused.pack" >/dev/null 2>"$hs_root/nocafile.err"
        hs_status=$?
        if [ "$hs_status" -ne 0 ] && [ ! -e "$hs_root/refused.pack" ] && grep -q "error: " "$hs_root/nocafile.err"; then
            note "https trust: a CA file that is not there is an error, not a silent fallback"
        else
            bad "https missing CA file" "status $hs_status" "$(head -3 "$hs_root/nocafile.err")"
        fi

        hs_wurl="https://localhost:$hs_wtls/git/repo.git"
        hs_with_ca "$WORK/t_httpfetch" clone "$hs_wurl" "$hs_root/refused.pack" >/dev/null 2>"$hs_root/wrong.err"
        hs_status=$?
        if [ "$hs_status" -ne 0 ] && [ ! -e "$hs_root/refused.pack" ] && grep -q "certificate was refused" "$hs_root/wrong.err"; then
            note "https trust: a certificate issued by the trusted CA but for another host name is refused"
        else
            bad "https hostname mismatch" "status $hs_status" "$(head -3 "$hs_root/wrong.err")"
        fi

        # --- redirects ---------------------------------------------------------------

        if hs_with_ca "$WORK/t_httpfetch" clone "https://localhost:$hs_otls/moved/repo.git" "$hs_root/moved.pack" >"$hs_root/moved.out" 2>"$hs_root/moved.err" &&
            git init -q --bare "$hs_root/idx2" && git -C "$hs_root/idx2" index-pack --stdin <"$hs_root/moved.pack" >/dev/null 2>&1; then
            note "https redirect: a same-origin 307 on the advertisement and on the POST is followed; the pack verifies"
        else
            bad "https same-origin redirect" "$(cat "$hs_root/moved.out")" "$(cat "$hs_root/moved.err")"
        fi

        if hs_with_ca "$WORK/t_httpfetch" ls-remote "http://localhost:$hs_oplain/upgrade/repo.git" >"$hs_root/up.got" 2>"$hs_root/up.err" &&
            GIT_SSL_CAINFO="$hs_ca" git ls-remote "$hs_url" | cmp -s - "$hs_root/up.got"; then
            note "https redirect: http to https on the same host is followed (upgrade)"
        else
            bad "https upgrade redirect" "$(head -3 "$hs_root/up.err")"
        fi

        rm -f "$hs_root/down.pack"
        hs_with_ca "$WORK/t_httpfetch" clone "https://localhost:$hs_otls/downgrade/repo.git" "$hs_root/down.pack" >/dev/null 2>"$hs_root/down.err"
        hs_status=$?
        if [ "$hs_status" -ne 0 ] && [ ! -e "$hs_root/down.pack" ] && grep -q "redirected https to http" "$hs_root/down.err"; then
            note "https redirect: https to http is refused (no cleartext hop), nothing written"
        else
            bad "https downgrade redirect" "status $hs_status" "$(head -3 "$hs_root/down.err")"
        fi

        # --- http is untouched -------------------------------------------------------

        if env -u GITUI_HTTP_CA_FILE "$WORK/t_httpfetch" ls-remote "http://localhost:$hs_oplain/git/repo.git" >"$hs_root/http.got" 2>"$hs_root/http.err" &&
            GIT_SSL_CAINFO="$hs_ca" git ls-remote "$hs_url" | cmp -s - "$hs_root/http.got"; then
            note "http: the plain listener of the same server still works with no CA configured"
        else
            bad "http still works" "$(head -3 "$hs_root/http.err")"
        fi

        # --- push over https, with auth ----------------------------------------------

        hs_tip=$(git -C "$hs_src" rev-parse main)
        got=$(hs_with_ca "$WORK/t_push" push "$hs_src/.git" "$hs_aurl" refs/heads/main 2>&1)
        if [ "$(git -C "$hs_asrv" rev-parse --verify -q refs/heads/main || echo none)" = none ] &&
            case "$got" in *"refused the push"*) true ;; *) false ;; esac; then
            note "https push: without credentials the auth server refuses; nothing on the server"
        else
            bad "https push without credentials" "$got"
        fi
        got=$(GITUI_HTTP_CA_FILE="$hs_certs/other-ca.pem" "$WORK/t_push" push "$hs_src/.git" "$hs_cred" refs/heads/main 2>&1)
        case "$got" in
            *fixture-pw*) bad "https push leaked the password on a refused certificate" "$got" ;;
            *"certificate was refused"*)
                if [ "$(git -C "$hs_asrv" rev-parse --verify -q refs/heads/main || echo none)" = none ]; then
                    note "https push: an untrusted certificate is refused before any credential is sent; nothing pushed"
                else
                    bad "https push to untrusted server pushed anyway"
                fi
                ;;
            *) bad "https push untrusted" "$got" ;;
        esac
        got=$(hs_with_ca "$WORK/t_push" push "$hs_src/.git" "https://pusher:bad-pw-7@localhost:$hs_atls/git/repo.git" refs/heads/main 2>&1)
        if [ "$(git -C "$hs_asrv" rev-parse --verify -q refs/heads/main || echo none)" = none ]; then
            case "$got" in
                *bad-pw-7*) bad "https push leaked the wrong password" "$got" ;;
                *"refused the push"*) note "https push: wrong credentials are refused; nothing pushed, the password is not printed" ;;
                *) bad "https push with wrong credentials" "$got" ;;
            esac
        else
            bad "https push with wrong credentials"
        fi
        got=$(hs_with_ca "$WORK/t_push" push "$hs_src/.git" "$hs_cred" refs/heads/main 2>&1)
        if [ "$(git -C "$hs_asrv" rev-parse refs/heads/main 2>/dev/null)" = "$hs_tip" ] &&
            git -C "$hs_asrv" fsck --full >"$hs_root/push.fsck" 2>&1; then
            case "$got" in
                *fixture-pw*) bad "https push leaked the password" "$got" ;;
                *) note "https push: credentials from the URL authenticate over TLS, the server holds the client's tip, git fsck --full is clean; the password is never printed" ;;
            esac
        else
            bad "https push with credentials" "$got" "$(cat "$hs_root/push.fsck" 2>/dev/null)"
        fi

        # Credentials from the environment, to a second branch, through a
        # same-origin redirect (POST included; the Authorization header is kept).
        git -C "$hs_src" branch feature main~1
        got=$(GITUI_HTTP_USER=pusher GITUI_HTTP_PASSWORD=fixture-pw GITUI_HTTP_CA_FILE="$hs_ca" \
            "$WORK/t_push" push "$hs_src/.git" "https://localhost:$hs_atls/moved/repo.git" refs/heads/feature 2>&1)
        if [ "$(git -C "$hs_asrv" rev-parse refs/heads/feature 2>/dev/null)" = "$(git -C "$hs_src" rev-parse feature)" ]; then
            case "$got" in
                *fixture-pw*) bad "https push (environment credentials) leaked the password" "$got" ;;
                *) note "https push: credentials from GITUI_HTTP_USER/PASSWORD, through a same-origin redirect, push a second branch" ;;
            esac
        else
            bad "https push via environment credentials and redirect" "$got"
        fi

        # The same fast-forward rule as over http: the server's `diverged` is a
        # commit this repository knows, but not an ancestor of its own `diverged`.
        (
            cd "$hs_src"
            git checkout -q -b other main~1
            echo o >o.txt
            git add -A
            git -c user.name=t -c user.email=t@e commit -q -m other
            git checkout -q -b diverged main~1
            echo d >d.txt
            git add -A
            git -c user.name=t -c user.email=t@e commit -q -m diverged
            git checkout -q main
        ) >/dev/null 2>&1
        git -C "$hs_src" push -q "$hs_asrv" other:refs/heads/diverged >/dev/null 2>&1
        got=$(hs_with_ca "$WORK/t_push" push "$hs_src/.git" "$hs_cred" refs/heads/diverged 2>&1)
        case "$got" in
            *"not a fast-forward"*) note "https push: a non-fast-forward is refused on the client over https as over http" ;;
            *) bad "https push non-fast-forward" "$got" ;;
        esac

        # --- pull over https -----------------------------------------------------------

        # A client cloned by real git (with credentials), then the other developer
        # pushes two commits; the pull fast-forwards.
        git -c http.sslCAInfo="$hs_ca" clone -q "$hs_cred" "$hs_root/pullcl" >/dev/null 2>&1
        git -C "$hs_root/pullcl" config user.email me@example.com
        git -C "$hs_root/pullcl" config user.name Me
        (
            cd "$hs_src"
            git checkout -q main
            echo "upstream 1" >up1.txt
            git add -A
            git commit -q -m "upstream 1"
            echo "upstream 2" >>big.txt
            git add -A
            git commit -q -m "upstream 2"
        ) >/dev/null 2>&1
        git -C "$hs_src" push -q "$hs_asrv" main >/dev/null 2>&1
        git -C "$hs_asrv" gc -q >/dev/null 2>&1
        hs_before=$(git -C "$hs_root/pullcl" rev-parse HEAD)
        hs_pull_url="https://localhost:$hs_atls/git/repo.git"

        got=$(hs_with_ca "$WORK/t_pull" pull "$hs_root/pullcl/.git" "$hs_root/pullcl" "$hs_pull_url" 2>&1)
        if [ "$(git -C "$hs_root/pullcl" rev-parse HEAD)" = "$hs_before" ]; then
            note "https pull: without credentials the auth server refuses; nothing moved"
        else
            bad "https pull without credentials moved HEAD" "$got"
        fi

        got=$(env -u GITUI_HTTP_CA_FILE "$WORK/t_pull" pull "$hs_root/pullcl/.git" "$hs_root/pullcl" "$hs_cred" 2>&1)
        case "$got" in
            *"certificate was refused"*)
                if [ "$(git -C "$hs_root/pullcl" rev-parse HEAD)" = "$hs_before" ]; then
                    note "https pull: an untrusted certificate is refused; nothing moved, no password printed"
                else
                    bad "https pull untrusted moved HEAD"
                fi
                ;;
            *) bad "https pull untrusted" "$got" ;;
        esac

        got=$(hs_with_ca "$WORK/t_pull" pull "$hs_root/pullcl/.git" "$hs_root/pullcl" "$hs_cred" 2>&1)
        if [ "$(git -C "$hs_root/pullcl" rev-parse HEAD)" = "$(git -C "$hs_src" rev-parse main)" ] &&
            git -C "$hs_root/pullcl" fsck --full >"$hs_root/pull.fsck" 2>&1 &&
            [ -z "$(git -C "$hs_root/pullcl" status --porcelain)" ] &&
            [ -f "$hs_root/pullcl/up1.txt" ]; then
            case "$got" in
                *fixture-pw*) bad "https pull leaked the password" "$got" ;;
                *) note "https pull: fast-forwarded over TLS with URL credentials; fsck clean, working tree matches, password never printed" ;;
            esac
        else
            bad "https pull" "$got" "$(head -5 "$hs_root/pull.fsck" 2>/dev/null)"
        fi

        got=$(hs_with_ca "$WORK/t_pull" pull "$hs_root/pullcl/.git" "$hs_root/pullcl" "$hs_cred" 2>&1)
        case "$got" in
            "up to date "*) note "https pull: a second pull reports up to date" ;;
            *) bad "https pull when up to date" "$got" ;;
        esac
    else
        bad "https servers" "did not come up: $(cat "$hs_root"/*.err 2>/dev/null | head -5)"
    fi
    hs_reap
    hs_pids=()
fi
