# The ssh transport (`GIT_ssh_transport.m31`) against a real, independent ssh
# server: a disposable OpenSSH `sshd`, run as the current user on an ephemeral
# port from a temp directory, with throwaway host and user keys and a throwaway
# $HOME -- the real ~/.ssh is never read or written. The server runs the real
# `git-upload-pack` and `git-receive-pack`, so the bytes on the wire are judged
# by git itself.
#
#   1. unit checks, no server (`t_ssh unit`): known_hosts lines (plain and
#      hashed), fingerprints, HashKnownHosts, ssh_config resolution;
#   2. fetch / pull / push through `GIT_ssh_transport`, the refs compared with
#      `git ls-remote` and the repositories judged by `git fsck --strict`:
#      fast-forward pull, a new branch, a fast-forward push, both kinds of
#      non-fast-forward refusal, `ssh://` and scp-like (ssh_config alias)
#      URLs, a nonstandard port, a path with spaces and quotes, the default
#      key and known_hosts when nothing overrides them;
#   3. a large remote (several MB of incompressible blobs, thousands of
#      objects -- more than the ssh window of 2 MiB) fetched into an empty
#      repository, and into one with 800 commits the server has never seen
#      (four rounds of `have`s, counted from the server's own packet trace);
#   4. the refusals: a key the server does not accept, an unknown host (and
#      then trusted, plain and hashed, the line read back by `ssh-keygen -F`),
#      a host key that differs from known_hosts, an encrypted key, a missing
#      key;
#   5. the interactive client under a pty (`pty_ssh.py`): F p against an
#      unknown host raises the confirm overlay, `n` sends nothing, `y` trusts
#      the key and pulls; P p pushes; a changed host key is refused.
#
# SKIPs, with a message, when sshd, ssh-keygen, git, python3 or git's two
# server programs are missing. Sourced from `test.sh`, sharing its shell,
# `$WORK`, `build`, `note`/`bad`. sshd is killed by its exact PID at the end
# (and by a watchdog if this shell dies first).

ss_root="$WORK/ssh"
ss_skip=""
ss_sshd=$(command -v sshd || true)
[ -z "$ss_sshd" ] && [ -x /usr/sbin/sshd ] && ss_sshd=/usr/sbin/sshd
[ -z "$ss_sshd" ] && ss_skip="sshd is not installed"
for ss_tool in ssh-keygen ssh git python3 git-upload-pack git-receive-pack; do
    if [ -z "$ss_skip" ] && ! PATH="$PATH:/usr/bin:/bin" command -v "$ss_tool" >/dev/null 2>&1; then
        ss_skip="$ss_tool is not installed"
    fi
done

if [ -n "$ss_skip" ]; then
    printf 'SKIP ssh transport tests: %s\n' "$ss_skip"
else
mkdir -p "$ss_root/home/.ssh" "$ss_root/repos"
ss_home="$ss_root/home"
ss_user=$(id -un)
ss_pid=""

ss_g() { git -c user.name=Tester -c user.email=t@example.com -c init.defaultBranch=main -c protocol.file.allow=always "$@"; }

# Run t_ssh as a user with a throwaway home. $ss_kh and $ss_id, when set,
# are the GITUI_SSH_KNOWN_HOSTS / GITUI_SSH_IDENTITY overrides.
# sshd gives a session its own short PATH (/usr/bin:/bin on macOS), which does
# not hold a Homebrew or hand-built git; hand it the directories git's two
# server programs were found in.
ss_session_path="$(dirname "$(command -v git-upload-pack)"):$(dirname "$(command -v git-receive-pack)"):/usr/bin:/bin:/usr/sbin:/sbin"
case "$ss_session_path" in *" "*) ss_session_path="/usr/bin:/bin:/usr/sbin:/sbin" ;; esac

ss_t() {
    local -a e=(HOME="$ss_home")
    [ -n "${ss_kh:-}" ] && e+=(GITUI_SSH_KNOWN_HOSTS="$ss_kh")
    [ -n "${ss_id:-}" ] && e+=(GITUI_SSH_IDENTITY="$ss_id")
    env "${e[@]}" "$WORK/t_ssh" "$@"
}

# ss_eq <name> <got> <want>
ss_eq() {
    if [ "$2" = "$3" ]; then
        note "ssh: $1"
    else
        bad "ssh: $1" "got:  $2" "want: $3"
    fi
}

# ss_has <name> <haystack> <needle>
ss_has() {
    case "$2" in
        *"$3"*) note "ssh: $1" ;;
        *) bad "ssh: $1" "wanted: $3" "got:    $2" ;;
    esac
}

# ss_lacks <name> <haystack> <needle>
ss_lacks() {
    case "$2" in
        *"$3"*) bad "ssh: $1" "must not contain: $3" "got: $2" ;;
        *) note "ssh: $1" ;;
    esac
}

ss_stop() {
    if [ -n "$ss_pid" ]; then
        kill "$ss_pid" >/dev/null 2>&1
        wait "$ss_pid" 2>/dev/null
        ss_pid=""
    fi
}

# --- keys, config, and a port ---------------------------------------------------

ssh-keygen -t ed25519 -f "$ss_root/host_key" -N "" -q
ssh-keygen -t ed25519 -f "$ss_root/other_host_key" -N "" -q
ssh-keygen -t ed25519 -f "$ss_root/user_key" -N "" -q -C "gitui ssh test"
ssh-keygen -t ed25519 -f "$ss_root/wrong_key" -N "" -q
ssh-keygen -t ed25519 -f "$ss_root/enc_key" -N "correct horse" -q
chmod 600 "$ss_root"/*_key
cp "$ss_root/user_key" "$ss_home/.ssh/id_ed25519"
chmod 600 "$ss_home/.ssh/id_ed25519"
cp "$ss_root/user_key" "$ss_home/alias_key"
chmod 600 "$ss_home/alias_key"
cp "$ss_root/user_key.pub" "$ss_root/authorized_keys"
ss_fp=$(ssh-keygen -lf "$ss_root/host_key.pub" | awk '{print $2}')
ss_other_fp=$(ssh-keygen -lf "$ss_root/other_host_key.pub" | awk '{print $2}')

ss_free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}
ss_port=$(ss_free_port)

write_ssh_config() {
    cat >"$ss_home/.ssh/config" <<EOF
# for the unit checks: nothing listens there
Host alias
  HostName 10.9.8.7
  Port 4222
  User aliasuser
  IdentityFile ~/alias_key

# the real server, by name (scp-like URLs, a port and a key from the config)
Host srv
  HostName 127.0.0.1
  Port $ss_port
  User $ss_user
  IdentityFile $ss_root/user_key

# the same, asking for hashed known_hosts entries
Host hsrv
  HostName 127.0.0.1
  Port $ss_port
  User $ss_user
  IdentityFile $ss_root/user_key
  HashKnownHosts yes
EOF
}

# --- 1. unit, no server ---------------------------------------------------------------

if build t_ssh; then
    write_ssh_config
    HOME="$ss_home" "$WORK/t_ssh" unit >"$ss_root/unit.out" 2>&1
    ss_ok=0
    while IFS= read -r ss_line; do
        case "$ss_line" in
            "ok "*)
                note "ssh unit: ${ss_line#ok }"
                ss_ok=$((ss_ok + 1))
                ;;
            *) bad "ssh unit: ${ss_line#FAIL }" ;;
        esac
    done <"$ss_root/unit.out"
    [ "$ss_ok" -eq 0 ] && bad "ssh unit produced no passing checks" "$(head -3 "$ss_root/unit.out")"

    # --- the server ---------------------------------------------------------------
    ss_up=0
    for ss_attempt in 1 2 3; do
        write_ssh_config
        cat >"$ss_root/sshd_config" <<EOF
Port $ss_port
ListenAddress 127.0.0.1
HostKey $ss_root/host_key
PidFile $ss_root/sshd.pid
AuthorizedKeysFile $ss_root/authorized_keys
StrictModes no
UsePAM no
KexAlgorithms curve25519-sha256
HostKeyAlgorithms ssh-ed25519
Ciphers chacha20-poly1305@openssh.com
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
MaxStartups 1000
LoginGraceTime 60
SetEnv GIT_TRACE_PACKET=$ss_root/trace.log PATH=$ss_session_path
EOF
        # OpenSSH 9.8+ drops a source that keeps disconnecting before auth (as the host-key
        # refusal tests do); older sshd rejects the keyword, so keep it only if accepted.
        printf 'PerSourcePenalties no\n' >>"$ss_root/sshd_config"
        if ! "$ss_sshd" -t -f "$ss_root/sshd_config" >/dev/null 2>&1; then
            sed '/^PerSourcePenalties/d' "$ss_root/sshd_config" >"$ss_root/sshd_config.new"
            mv "$ss_root/sshd_config.new" "$ss_root/sshd_config"
        fi
        "$ss_sshd" -f "$ss_root/sshd_config" -D -e >"$ss_root/sshd.log" 2>&1 &
        ss_pid=$!
        for ss_try in $(seq 1 100); do
            if (exec 3<>"/dev/tcp/127.0.0.1/$ss_port") 2>/dev/null; then
                exec 3>&-
                ss_up=1
                break
            fi
            kill -0 "$ss_pid" 2>/dev/null || break
            sleep 0.05
        done
        [ "$ss_up" = 1 ] && break
        ss_stop
        ss_port=$(ss_free_port)
    done
    if [ "$ss_up" = 1 ]; then
        # If this shell dies without reaching ss_stop, the server must not outlive it.
        ( while kill -0 $$ 2>/dev/null; do sleep 1; done; kill "$ss_pid" 2>/dev/null ) >/dev/null 2>&1 &
        ss_watch=$!
        disown "$ss_watch" 2>/dev/null
    else
        bad "ssh: sshd did not come up" "$(cat "$ss_root/sshd.log")"
    fi
fi

if [ "${ss_up:-0}" = 1 ]; then
    # The fixture itself, judged by the real client, so a failure of ours is not
    # blamed on a broken fixture.
    ss_real=$(ssh -F /dev/null -p "$ss_port" -i "$ss_root/user_key" -o IdentitiesOnly=yes \
        -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o BatchMode=yes \
        "$ss_user@127.0.0.1" 'echo fixture-ok' 2>"$ss_root/real_ssh.err")
    if [ "$ss_real" != "fixture-ok" ]; then
        bad "ssh: the real ssh client cannot log in to the fixture sshd" "$(cat "$ss_root/real_ssh.err")" "$(tail -5 "$ss_root/sshd.log")"
        ss_up=0
    fi
fi

if [ "${ss_up:-0}" = 1 ]; then
    note "ssh: disposable sshd on 127.0.0.1:$ss_port, real ssh client logs in"
    ss_fail0=$fail

    ss_kh="$ss_root/known_hosts"
    ss_id="$ss_root/user_key"
    printf '[127.0.0.1]:%s %s %s\n' "$ss_port" $(cut -d' ' -f1,2 "$ss_root/host_key.pub") >"$ss_kh"
    ss_url_of() { echo "ssh://$ss_user@127.0.0.1:$ss_port$1"; }

    # --- fixtures: a remote with history, and the clones around it ---------------------
    ss_bare="$ss_root/repos/main.git"
    (
        set -e
        ss_g init -q --bare "$ss_bare"
        ss_g init -q "$ss_root/seed"
        cd "$ss_root/seed"
        for ss_n in 1 2 3 4 5; do
            echo "line $ss_n" >"file$ss_n.txt"
            ss_g add -A
            ss_g commit -q -m "seed $ss_n"
        done
        ss_g tag -a -m "tagged" v1
        ss_g remote add origin "$ss_bare"
        ss_g push -q origin main v1
    ) >"$ss_root/fixture.log" 2>&1 || bad "ssh: fixture" "$(tail -5 "$ss_root/fixture.log")"

    # --- 2. ls, pull, fetch ------------------------------------------------------------
    ss_t ls "$(ss_url_of "$ss_bare")" 2>"$ss_root/ls.err" | sort >"$ss_root/ls.got"
    git ls-remote "$ss_bare" | sort >"$ss_root/ls.want"
    if cmp -s "$ss_root/ls.got" "$ss_root/ls.want" && [ -s "$ss_root/ls.want" ]; then
        note "ssh: the advertisement matches git ls-remote ($(wc -l <"$ss_root/ls.want") refs, peeled tag included)"
    else
        bad "ssh: ls over ssh:// matches git ls-remote" "$(diff "$ss_root/ls.got" "$ss_root/ls.want" | head -6)" "$(cat "$ss_root/ls.err")"
    fi

    ss_g clone -q "$ss_bare" "$ss_root/c1" 2>/dev/null
    ss_g clone -q "$ss_bare" "$ss_root/other" 2>/dev/null
    ss_up_commit() { # <repo> <file> <text>
        echo "$3" >"$1/$2"
        ss_g -C "$1" add -A
        ss_g -C "$1" commit -q -m "update $2"
    }
    ss_up_commit "$ss_root/other" up1.txt "from upstream"
    ss_up_commit "$ss_root/other" up2.txt "from upstream again"
    ss_g -C "$ss_root/other" push -q origin main 2>/dev/null
    ss_old=$(git -C "$ss_root/c1" rev-parse HEAD)
    ss_want=$(git -C "$ss_root/other" rev-parse HEAD)
    ss_out=$(ss_t pull "$(ss_url_of "$ss_bare")" "$ss_root/c1/.git" "$ss_root/c1" 2>&1)
    ss_has "pull over ssh:// reports the fast-forward" "$ss_out" "pulled $ss_old $ss_want"
    ss_eq "pull: HEAD is the remote tip" "$(git -C "$ss_root/c1" rev-parse HEAD)" "$ss_want"
    ss_eq "pull: the working tree has the new files" "$(cat "$ss_root/c1/up2.txt" 2>/dev/null)" "from upstream again"
    ss_eq "pull: git status is clean" "$(git -C "$ss_root/c1" status --porcelain)" ""
    ss_eq "pull: git fsck --strict is clean" "$(git -C "$ss_root/c1" fsck --strict 2>&1 >/dev/null | head -3)" ""
    ss_eq "pull: the remote-tracking ref follows" "$(git -C "$ss_root/c1" rev-parse refs/remotes/origin/main)" "$ss_want"
    ss_out=$(ss_t pull "$(ss_url_of "$ss_bare")" "$ss_root/c1/.git" "$ss_root/c1" 2>&1)
    ss_has "pull again: up to date" "$ss_out" "up to date $ss_want"

    # scp-like URL by ssh_config alias: port, user and key all from ~/.ssh/config
    ss_up_commit "$ss_root/other" up3.txt "third"
    ss_g -C "$ss_root/other" push -q origin main 2>/dev/null
    ss_want=$(git -C "$ss_root/other" rev-parse HEAD)
    ss_out=$(ss_id="" ss_t pull "srv:$ss_bare" "$ss_root/c1/.git" "$ss_root/c1" 2>&1)
    ss_has "pull over an scp-like URL (ssh_config alias, IdentityFile)" "$ss_out" "pulled "
    ss_eq "pull (scp-like): HEAD is the remote tip" "$(git -C "$ss_root/c1" rev-parse HEAD)" "$ss_want"

    # No override of anything: ~/.ssh/id_ed25519 and ~/.ssh/known_hosts of the throwaway HOME.
    cp "$ss_kh" "$ss_home/.ssh/known_hosts"
    ss_up_commit "$ss_root/other" up4.txt "fourth"
    ss_g -C "$ss_root/other" push -q origin main 2>/dev/null
    ss_want=$(git -C "$ss_root/other" rev-parse HEAD)
    ss_out=$(ss_kh="" ss_id="" ss_t pull "$(ss_url_of "$ss_bare")" "$ss_root/c1/.git" "$ss_root/c1" 2>&1)
    ss_has "pull with the default key and ~/.ssh/known_hosts" "$ss_out" "pulled "
    ss_eq "pull (defaults): HEAD is the remote tip" "$(git -C "$ss_root/c1" rev-parse HEAD)" "$ss_want"
    rm -f "$ss_home/.ssh/known_hosts"

    # fetch with haves: the pack is judged by git
    ss_up_commit "$ss_root/other" up5.txt "fifth"
    ss_g -C "$ss_root/other" push -q origin main 2>/dev/null
    ss_out=$(ss_t fetch "$(ss_url_of "$ss_bare")" "$ss_root/c1/.git" "$ss_root/fetch1.pack" 2>&1)
    ss_has "fetch with haves: pack received" "$ss_out" "pack "
    if git -C "$ss_root/c1" index-pack --strict "$ss_root/fetch1.pack" >/dev/null 2>"$ss_root/idx.err"; then
        note "ssh: fetch with haves: git index-pack --strict accepts the pack"
    else
        bad "ssh: fetch with haves: git index-pack --strict" "$(head -3 "$ss_root/idx.err")"
    fi

    # --- push ------------------------------------------------------------------------
    ss_push_bare="$ss_root/repos/push.git"
    ss_g init -q --bare "$ss_push_bare"
    ss_g -C "$ss_root/seed" push -q "$ss_push_bare" main 2>/dev/null
    ss_g clone -q "$ss_push_bare" "$ss_root/pc" 2>/dev/null
    ss_g clone -q "$ss_push_bare" "$ss_root/po" 2>/dev/null
    ss_purl=$(ss_url_of "$ss_push_bare")

    ss_g -C "$ss_root/pc" checkout -q -b feature
    ss_up_commit "$ss_root/pc" feat.txt "a feature"
    ss_out=$(ss_t push "$ss_purl" "$ss_root/pc/.git" refs/heads/feature 2>&1)
    ss_has "push: a new branch" "$ss_out" "ok refs/heads/feature"
    ss_eq "push: the new branch is on the remote" "$(git ls-remote "$ss_push_bare" refs/heads/feature | cut -f1)" "$(git -C "$ss_root/pc" rev-parse feature)"
    ss_eq "push: remote git fsck --strict is clean" "$(git -C "$ss_push_bare" fsck --strict 2>&1 | head -3)" ""

    ss_up_commit "$ss_root/pc" feat2.txt "more"
    ss_out=$(ss_t push "$ss_purl" "$ss_root/pc/.git" refs/heads/feature 2>&1)
    ss_has "push: a fast-forward" "$ss_out" "ok refs/heads/feature"
    ss_eq "push: the remote branch moved to the new tip" "$(git ls-remote "$ss_push_bare" refs/heads/feature | cut -f1)" "$(git -C "$ss_root/pc" rev-parse feature)"
    ss_eq "push: remote git fsck --strict is clean after the fast-forward" "$(git -C "$ss_push_bare" fsck --strict 2>&1 | head -3)" ""

    ss_out=$(ss_t push "$ss_purl" "$ss_root/pc/.git" refs/heads/feature 2>&1)
    ss_has "push: nothing new is refused as up to date" "$ss_out" "up to date"

    # non-fast-forward, the remote moved on commits we do not have
    ss_up_commit "$ss_root/po" theirs.txt "someone else"
    ss_g -C "$ss_root/po" push -q origin main 2>/dev/null
    ss_g -C "$ss_root/pc" checkout -q main 2>/dev/null
    ss_up_commit "$ss_root/pc" ours.txt "us, on a stale main"
    ss_before=$(git ls-remote "$ss_push_bare" refs/heads/main | cut -f1)
    ss_out=$(ss_t push "$ss_purl" "$ss_root/pc/.git" refs/heads/main 2>&1)
    ss_rc=$?
    ss_has "push: a stale branch is refused" "$ss_out" "refused"
    ss_eq "push: the refusal exits non-zero" "$([ "$ss_rc" -ne 0 ] && echo yes)" "yes"
    ss_eq "push: the remote branch is untouched by the refusal" "$(git ls-remote "$ss_push_bare" refs/heads/main | cut -f1)" "$ss_before"

    # non-fast-forward where we do have their commit: fetch, then rewrite
    ss_g -C "$ss_root/pc" fetch -q origin 2>/dev/null
    ss_g -C "$ss_root/pc" reset -q --hard origin/main
    ss_g -C "$ss_root/pc" commit -q --amend -m "rewritten tip" --allow-empty
    ss_before=$(git ls-remote "$ss_push_bare" refs/heads/main | cut -f1)
    ss_out=$(ss_t push "$ss_purl" "$ss_root/pc/.git" refs/heads/main 2>&1)
    ss_has "push: a rewritten tip is refused as not a fast-forward" "$ss_out" "not a fast-forward"
    ss_eq "push: the remote branch is untouched by that refusal" "$(git ls-remote "$ss_push_bare" refs/heads/main | cut -f1)" "$ss_before"

    # --- SHA-256 repositories over ssh: the object-format capability, 64-digit ids, the pack's
    # 32-octet trailer, and the refusals between formats. Explicit --object-format, so these
    # run the same whatever TEST_HASH says; everything is judged by git. ----------------------
    ss_s2_bare="$ss_root/repos/sha256.git"
    ss_s1_bare="$ss_root/repos/sha1.git"
    (
        set -e
        ss_g init -q --bare --object-format=sha256 "$ss_s2_bare"
        ss_g init -q --bare --object-format=sha1 "$ss_s1_bare"
        ss_g init -q --object-format=sha256 "$ss_root/s2seed"
        cd "$ss_root/s2seed"
        for ss_n in 1 2 3 4; do
            echo "sha256 line $ss_n" >"s$ss_n.txt"
            ss_g add -A
            ss_g commit -q -m "s2 seed $ss_n"
        done
        ss_g tag -a -m "tagged" s2v1
        ss_g push -q "$ss_s2_bare" main s2v1
        ss_g init -q --object-format=sha1 "$ss_root/s1seed"
        cd "$ss_root/s1seed"
        echo "sha1 line" >one.txt
        ss_g add -A
        ss_g commit -q -m "s1 seed"
        ss_g push -q "$ss_s1_bare" main
    ) >"$ss_root/s2fixture.log" 2>&1 || bad "ssh sha256: fixture" "$(tail -5 "$ss_root/s2fixture.log")"
    ss_t ls "$(ss_url_of "$ss_s2_bare")" 2>"$ss_root/s2ls.err" | sort >"$ss_root/s2ls.got"
    git ls-remote "$ss_s2_bare" | sort >"$ss_root/s2ls.want"
    if cmp -s "$ss_root/s2ls.got" "$ss_root/s2ls.want" && [ -s "$ss_root/s2ls.want" ] \
        && [ "$(head -1 "$ss_root/s2ls.got" | cut -f1 | tr -d '\n' | wc -c | tr -d ' ')" = 64 ]; then
        note "ssh sha256: the advertisement (64-digit ids) matches git ls-remote"
    else
        bad "ssh sha256: ls matches git ls-remote" "$(diff "$ss_root/s2ls.got" "$ss_root/s2ls.want" | head -4)" "$(cat "$ss_root/s2ls.err")"
    fi
    ss_g clone -q "$ss_s2_bare" "$ss_root/s2c" 2>/dev/null
    ss_g clone -q "$ss_s2_bare" "$ss_root/s2o" 2>/dev/null
    ss_eq "sha256: the clone is a SHA-256 repository" "$(git -C "$ss_root/s2c" rev-parse --show-object-format)" "sha256"
    ss_up_commit "$ss_root/s2o" up1.txt "from upstream"
    ss_up_commit "$ss_root/s2o" up2.txt "from upstream again"
    ss_g -C "$ss_root/s2o" push -q origin main 2>/dev/null
    ss_old=$(git -C "$ss_root/s2c" rev-parse HEAD)
    ss_want=$(git -C "$ss_root/s2o" rev-parse HEAD)
    ss_out=$(ss_t pull "$(ss_url_of "$ss_s2_bare")" "$ss_root/s2c/.git" "$ss_root/s2c" 2>&1)
    ss_has "sha256: pull reports the fast-forward" "$ss_out" "pulled $ss_old $ss_want"
    ss_eq "sha256: pull: HEAD is the remote tip" "$(git -C "$ss_root/s2c" rev-parse HEAD)" "$ss_want"
    ss_eq "sha256: pull: git status is clean" "$(git -C "$ss_root/s2c" status --porcelain)" ""
    ss_eq "sha256: pull: git fsck --strict is clean" "$(git -C "$ss_root/s2c" fsck --strict 2>&1 >/dev/null | head -3)" ""
    ss_out=$(ss_t pull "$(ss_url_of "$ss_s2_bare")" "$ss_root/s2c/.git" "$ss_root/s2c" 2>&1)
    ss_has "sha256: pull again: up to date" "$ss_out" "up to date $ss_want"

    ss_up_commit "$ss_root/s2o" up3.txt "third"
    ss_g -C "$ss_root/s2o" push -q origin main 2>/dev/null
    ss_out=$(ss_t fetch "$(ss_url_of "$ss_s2_bare")" "$ss_root/s2c/.git" "$ss_root/s2fetch.pack" 2>&1)
    ss_has "sha256: fetch with haves: pack received" "$ss_out" "pack "
    if git -C "$ss_root/s2c" index-pack --strict "$ss_root/s2fetch.pack" >/dev/null 2>"$ss_root/s2idx.err"; then
        note "ssh sha256: fetch: git index-pack --strict accepts the pack"
    else
        bad "ssh sha256: fetch: git index-pack --strict" "$(head -3 "$ss_root/s2idx.err")"
    fi

    ss_g -C "$ss_root/s2c" checkout -q -b feature
    ss_up_commit "$ss_root/s2c" feat.txt "a feature"
    ss_out=$(ss_t push "$(ss_url_of "$ss_s2_bare")" "$ss_root/s2c/.git" refs/heads/feature 2>&1)
    ss_has "sha256: push: a new branch" "$ss_out" "ok refs/heads/feature"
    ss_eq "sha256: push: the branch is on the remote" "$(git ls-remote "$ss_s2_bare" refs/heads/feature | cut -f1)" "$(git -C "$ss_root/s2c" rev-parse feature)"
    ss_up_commit "$ss_root/s2c" feat2.txt "more"
    ss_out=$(ss_t push "$(ss_url_of "$ss_s2_bare")" "$ss_root/s2c/.git" refs/heads/feature 2>&1)
    ss_has "sha256: push: a fast-forward" "$ss_out" "ok refs/heads/feature"
    ss_eq "sha256: push: remote git fsck --strict is clean" "$(git -C "$ss_s2_bare" fsck --strict 2>&1 | head -3)" ""
    ss_out=$(ss_t push "$(ss_url_of "$ss_s2_bare")" "$ss_root/s2c/.git" refs/heads/feature 2>&1)
    ss_has "sha256: push: nothing new is up to date" "$ss_out" "up to date"

    # between the formats, in both directions, for pull and for push: refused before anything moves
    ss_g clone -q "$ss_s1_bare" "$ss_root/s1c" 2>/dev/null
    ss_g -C "$ss_root/s1c" checkout -q -b feature
    ss_up_commit "$ss_root/s1c" f.txt "sha1 side"
    ss_s1_tip=$(git -C "$ss_root/s1c" rev-parse HEAD)
    ss_before=$(git ls-remote "$ss_s2_bare" | sort)
    ss_out=$(ss_t push "$(ss_url_of "$ss_s2_bare")" "$ss_root/s1c/.git" refs/heads/feature 2>&1)
    ss_has "sha256: a SHA-1 repository cannot push to a SHA-256 remote" "$ss_out" "object format"
    ss_eq "sha256: ... and the remote is untouched" "$(git ls-remote "$ss_s2_bare" | sort)" "$ss_before"
    ss_g -C "$ss_root/s1c" checkout -q main
    ss_out=$(ss_t pull "$(ss_url_of "$ss_s2_bare")" "$ss_root/s1c/.git" "$ss_root/s1c" 2>&1)
    ss_has "sha256: a SHA-1 repository cannot pull from a SHA-256 remote" "$ss_out" "object format"
    ss_eq "sha256: ... and its HEAD did not move" "$(git -C "$ss_root/s1c" rev-parse HEAD)" "$(git -C "$ss_root/s1c" rev-parse main)"
    ss_before=$(git ls-remote "$ss_s1_bare" | sort)
    ss_out=$(ss_t push "$(ss_url_of "$ss_s1_bare")" "$ss_root/s2c/.git" refs/heads/feature 2>&1)
    ss_has "sha256: a SHA-256 repository cannot push to a SHA-1 remote" "$ss_out" "object format"
    ss_eq "sha256: ... and the remote is untouched" "$(git ls-remote "$ss_s1_bare" | sort)" "$ss_before"
    ss_out=$(ss_t pull "$(ss_url_of "$ss_s1_bare")" "$ss_root/s2c/.git" "$ss_root/s2c" 2>&1)
    ss_has "sha256: a SHA-256 repository cannot pull from a SHA-1 remote" "$ss_out" "object format"

    # --- a path with spaces and quotes ---------------------------------------------
    ss_odd="$ss_root/repos/it's a \"quoted\" repo.git"
    ss_g init -q --bare "$ss_odd"
    ss_g -C "$ss_root/seed" push -q "$ss_odd" main 2>/dev/null
    ss_enc=$(printf '%s' "$ss_odd" | sed -e 's/ /%20/g' -e "s/'/%27/g" -e 's/"/%22/g')
    ss_t ls "ssh://$ss_user@127.0.0.1:$ss_port$ss_enc" 2>"$ss_root/odd.err" | sort >"$ss_root/odd.got"
    git ls-remote "$ss_odd" | sort >"$ss_root/odd.want"
    if cmp -s "$ss_root/odd.got" "$ss_root/odd.want" && [ -s "$ss_root/odd.want" ]; then
        note "ssh: a path with spaces, a single quote and double quotes (ssh:// percent-encoded)"
    else
        bad "ssh: odd path over ssh://" "$(cat "$ss_root/odd.err")" "$(diff "$ss_root/odd.got" "$ss_root/odd.want" | head -4)"
    fi
    ss_id="" ss_t ls "srv:$ss_odd" 2>"$ss_root/odd2.err" | sort >"$ss_root/odd2.got"
    if cmp -s "$ss_root/odd2.got" "$ss_root/odd.want"; then
        note "ssh: the same path as an scp-like URL"
    else
        bad "ssh: odd path over an scp-like URL" "$(cat "$ss_root/odd2.err")" "$(diff "$ss_root/odd2.got" "$ss_root/odd.want" | head -4)"
    fi
    ss_g clone -q "$ss_odd" "$ss_root/oddc" 2>/dev/null
    ss_g -C "$ss_root/oddc" checkout -q -b odd-branch
    ss_up_commit "$ss_root/oddc" odd.txt "odd"
    ss_out=$(ss_t push "ssh://$ss_user@127.0.0.1:$ss_port$ss_enc" "$ss_root/oddc/.git" refs/heads/odd-branch 2>&1)
    ss_has "push to the odd path" "$ss_out" "ok refs/heads/odd-branch"
    ss_eq "push to the odd path: the ref is there" "$(git ls-remote "$ss_odd" refs/heads/odd-branch | cut -f1)" "$(git -C "$ss_root/oddc" rev-parse odd-branch)"

    # --- 3. a large remote --------------------------------------------------------------
    ss_big="$ss_root/repos/big.git"
    ss_g init -q --bare "$ss_big"
    python3 - "$ss_root/big.stream" <<'PY'
import random, sys
rng = random.Random(7)
out = open(sys.argv[1], "wb")
def data(b):
    out.write(b"data %d\n" % len(b)); out.write(b); out.write(b"\n")
commits = 600
for c in range(commits):
    out.write(b"commit refs/heads/main\n")
    out.write(b"committer T <t@example.com> %d +0000\n" % (1700000000 + c))
    data(b"big %d" % c)
    for k in range(4):
        out.write(b"M 100644 inline d%d/f%d_%d.bin\n" % (c % 40, c, k))
        data(rng.randbytes(3000))
    out.write(b"\n")
PY
    git -C "$ss_big" fast-import --quiet <"$ss_root/big.stream" 2>"$ss_root/big.err" || bad "ssh: big fixture" "$(head -3 "$ss_root/big.err")"
    ss_big_objects=$(git -C "$ss_big" rev-list --objects --all | wc -l)
    ss_big_tip=$(git -C "$ss_big" rev-parse main)

    git init -q -b main "$ss_root/empty"
    : >"$ss_root/trace.log"
    ss_start=$(date +%s)
    ss_out=$(ss_t fetch "$(ss_url_of "$ss_big")" "$ss_root/empty/.git" "$ss_root/big.pack" 2>&1)
    ss_secs=$(($(date +%s) - ss_start))
    ss_size=$(wc -c <"$ss_root/big.pack" 2>/dev/null || echo 0)
    ss_eq "large fetch: every object arrives ($ss_big_objects objects, $((ss_size / 1024)) KiB, ${ss_secs}s)" "$(echo "$ss_out" | awk '/^pack /{print $3}')" "$ss_big_objects"
    if [ "$ss_size" -gt $((3 * 1024 * 1024)) ]; then
        note "ssh: large fetch: the pack ($((ss_size / 1024)) KiB) is larger than the 2 MiB ssh window"
    else
        bad "ssh: large fetch: the pack was meant to exceed the ssh window" "size $ss_size"
    fi
    if git -C "$ss_root/empty" index-pack --strict --stdin <"$ss_root/big.pack" >/dev/null 2>"$ss_root/idx.err" \
        && git -C "$ss_root/empty" update-ref refs/heads/main "$ss_big_tip" \
        && [ -z "$(git -C "$ss_root/empty" fsck --strict --no-dangling 2>&1)" ]; then
        note "ssh: large fetch: git index-pack --strict and git fsck --strict accept it, tip reachable"
    else
        bad "ssh: large fetch: git rejects the pack" "$(head -3 "$ss_root/idx.err")" "$(git -C "$ss_root/empty" fsck --strict 2>&1 | head -3)"
    fi

    # 800 commits the server has never seen: four rounds of haves
    git init -q -b main "$ss_root/diverged"
    python3 - "$ss_root/dv.stream" <<'PY'
import sys
out = open(sys.argv[1], "wb")
for c in range(800):
    out.write(b"commit refs/heads/main\ncommitter T <t@example.com> %d +0000\n" % (1600000000 + c))
    msg = b"local %d" % c
    out.write(b"data %d\n%s\n" % (len(msg), msg))
    body = b"local file %d\n" % c
    out.write(b"M 100644 inline l%d.txt\ndata %d\n%s\n\n" % (c, len(body), body))
PY
    git -C "$ss_root/diverged" fast-import --quiet <"$ss_root/dv.stream" 2>/dev/null
    : >"$ss_root/trace.log"
    ss_out=$(ss_t fetch "$(ss_url_of "$ss_big")" "$ss_root/diverged/.git" "$ss_root/dv.pack" 2>&1)
    ss_has "negotiation: 800 haves the server does not know are all sent" "$ss_out" "haves 800"
    ss_haves=$(grep -c 'upload-pack< have ' "$ss_root/trace.log")
    ss_naks=$(grep -c 'upload-pack> NAK' "$ss_root/trace.log")
    ss_eq "negotiation: the server received 800 haves (its own packet trace)" "$ss_haves" "800"
    if [ "$ss_naks" -ge 3 ]; then
        note "ssh: negotiation: several rounds ($ss_naks NAKs in the server's trace), replies read between rounds"
    else
        bad "ssh: negotiation: expected several rounds" "NAKs in the server's trace: $ss_naks"
    fi
    ss_eq "negotiation: the pack has every object" "$(echo "$ss_out" | awk '/^pack /{print $3}')" "$ss_big_objects"
    if git -C "$ss_root/diverged" index-pack --strict "$ss_root/dv.pack" >/dev/null 2>"$ss_root/idx.err"; then
        note "ssh: negotiation: git index-pack --strict accepts the pack"
    else
        bad "ssh: negotiation: git index-pack --strict" "$(head -3 "$ss_root/idx.err")"
    fi

    # a big push too: all of the large repository to an empty remote
    ss_bigpush="$ss_root/repos/bigpush.git"
    ss_g init -q --bare "$ss_bigpush"
    ss_g clone -q "$ss_big" "$ss_root/bigc" 2>/dev/null
    ss_start=$(date +%s)
    ss_out=$(ss_t push "$(ss_url_of "$ss_bigpush")" "$ss_root/bigc/.git" refs/heads/main 2>&1)
    ss_secs=$(($(date +%s) - ss_start))
    ss_has "large push: accepted (${ss_secs}s)" "$ss_out" "ok refs/heads/main"
    ss_eq "large push: the remote tip is ours" "$(git -C "$ss_bigpush" rev-parse main 2>/dev/null)" "$ss_big_tip"
    ss_eq "large push: remote git fsck --strict is clean" "$(git -C "$ss_bigpush" fsck --strict 2>&1 | head -3)" ""

    # --- 4. refusals --------------------------------------------------------------------
    ss_url=$(ss_url_of "$ss_bare")
    ss_before=$(git ls-remote "$ss_bare" | sort)

    ss_out=$(ss_id="$ss_root/wrong_key" ss_t ls "$ss_url" 2>&1)
    ss_rc=$?
    ss_eq "wrong key: refused" "$([ "$ss_rc" -ne 0 ] && echo refused)" "refused"
    ss_has "wrong key: the message says authentication failed" "$ss_out" "error:"
    ss_lacks "wrong key: it is not mistaken for an unknown host" "$ss_out" "unknown-host"

    ss_out=$(ss_id="$ss_root/enc_key" ss_t ls "$ss_url" 2>&1)
    ss_has "encrypted key: says passphrase-protected" "$ss_out" "passphrase-protected"
    ss_has "encrypted key: names https as the alternative" "$ss_out" "https://"
    ss_out=$(ss_id="$ss_root/nonexistent_key" ss_t ls "$ss_url" 2>&1)
    ss_has "missing key: says no ssh key found" "$ss_out" "no ssh key found"
    ss_has "missing key: names https as the alternative" "$ss_out" "https://"

    # unknown host: refused, nothing sent, then trusted
    ss_kh="$ss_root/kh_new/known_hosts"
    ss_out=$(ss_t ls "$ss_url" 2>&1)
    ss_rc=$?
    ss_eq "unknown host: refused with exit 3 and the fingerprint" "$ss_rc $ss_out" "3 unknown-host $ss_fp"
    ss_eq "unknown host: known_hosts was not created" "$([ -e "$ss_kh" ] && echo exists || echo absent)" "absent"
    printf 'elsewhere.example %s %s\n' $(cut -d' ' -f1,2 "$ss_root/host_key.pub") >"$ss_root/kh_other"
    ss_kh="$ss_root/kh_other"
    ss_out=$(ss_t ls "$ss_url" 2>&1)
    ss_eq "unknown host: also when known_hosts names only other hosts" "$ss_out" "unknown-host $ss_fp"
    ss_eq "unknown host: no refs were advertised to us, remote untouched" "$(git ls-remote "$ss_bare" | sort)" "$ss_before"

    ss_kh="$ss_root/kh_new/known_hosts"
    ss_out=$(ss_t trust "$ss_url" 2>&1)
    ss_has "trust: records the key" "$ss_out" "trusted $ss_fp"
    ss_eq "trust: ssh-keygen -F finds the plain line" "$(ssh-keygen -F "[127.0.0.1]:$ss_port" -f "$ss_kh" 2>/dev/null | grep -c ssh-ed25519)" "1"
    ss_eq "trust: the line is plain, not hashed" "$(grep -c '^\[127.0.0.1\]:'"$ss_port"' ssh-ed25519 ' "$ss_kh")" "1"
    ss_real=$(ssh -F /dev/null -p "$ss_port" -i "$ss_root/user_key" -o IdentitiesOnly=yes -o UserKnownHostsFile="$ss_kh" \
        -o StrictHostKeyChecking=yes -o BatchMode=yes "$ss_user@127.0.0.1" 'echo fine' 2>&1)
    ss_eq "trust: the real ssh accepts the file ours wrote" "$ss_real" "fine"
    ss_eq "trust: afterwards the same ls works and matches git ls-remote" "$(ss_t ls "$ss_url" 2>&1 | sort)" "$(git ls-remote "$ss_bare" | sort)"

    # hashed, under HashKnownHosts yes
    ss_kh="$ss_root/kh_hashed"
    rm -f "$ss_kh"
    ss_out=$(ss_id="" ss_t trust "hsrv:$ss_bare" 2>&1)
    ss_has "trust (HashKnownHosts yes): records the key" "$ss_out" "trusted $ss_fp"
    ss_eq "trust (HashKnownHosts yes): the line is hashed" "$(grep -c '^|1|' "$ss_kh")" "1"
    ss_eq "trust (HashKnownHosts yes): the host name is not in the file" "$(grep -c '127.0.0.1' "$ss_kh")" "0"
    ss_eq "trust (HashKnownHosts yes): ssh-keygen -F finds it by name" "$(ssh-keygen -F "[127.0.0.1]:$ss_port" -f "$ss_kh" 2>/dev/null | grep -c ssh-ed25519)" "1"
    ss_eq "trust (HashKnownHosts yes): ls then works" "$(ss_id="" ss_t ls "hsrv:$ss_bare" 2>&1 | sort)" "$(git ls-remote "$ss_bare" | sort)"
    ss_id="$ss_root/user_key"

    # a host key that differs from known_hosts
    ss_kh="$ss_root/kh_wrong"
    printf '[127.0.0.1]:%s %s %s\n' "$ss_port" $(cut -d' ' -f1,2 "$ss_root/other_host_key.pub") >"$ss_kh"
    ss_sum=$(cksum <"$ss_kh")
    ss_out=$(ss_t ls "$ss_url" 2>&1)
    ss_rc=$?
    ss_has "host key mismatch: refused" "$ss_out" "REFUSED"
    ss_has "host key mismatch: says the key does not match" "$ss_out" "does not match known_hosts"
    ss_has "host key mismatch: names the fingerprint the server presented" "$ss_out" "$ss_fp"
    ss_lacks "host key mismatch: no offer to trust it" "$ss_out" "unknown-host"
    ss_eq "host key mismatch: exit status is non-zero" "$([ "$ss_rc" -ne 0 ] && echo yes)" "yes"
    ss_out=$(ss_t trust "$ss_url" 2>&1)
    ss_eq "host key mismatch: known_hosts is never rewritten" "$(cksum <"$ss_kh")" "$ss_sum"
    ss_out=$(ss_t push "$ss_purl" "$ss_root/pc/.git" refs/heads/feature 2>&1)
    ss_has "host key mismatch: a push is refused too" "$ss_out" "REFUSED"
    ss_eq "host key mismatch: nothing reached the remote" "$(git ls-remote "$ss_bare" | sort)" "$ss_before"

    printf '@revoked [127.0.0.1]:%s %s %s\n' "$ss_port" $(cut -d' ' -f1,2 "$ss_root/host_key.pub") >"$ss_kh"
    ss_out=$(ss_t ls "$ss_url" 2>&1)
    ss_has "revoked host key: refused" "$ss_out" "revoked"

    # --- 5. the interactive client under a pty ------------------------------------------
    if bash scripts/build-gitui.sh -o "$WORK/gitui_ssh" >"$ss_root/gitui_build.log" 2>&1; then
        ss_pty_bare="$ss_root/repos/pty.git"
        ss_g init -q --bare "$ss_pty_bare"
        ss_g -C "$ss_root/seed" push -q "$ss_pty_bare" main 2>/dev/null
        rm -rf "$ss_root/pty"
        if out=$(HOME="$ss_home" GITUI_SSH_IDENTITY="$ss_root/user_key" GITUI_SSH_KNOWN_HOSTS="$ss_root/pty_kh/known_hosts" \
            python3 tests/pty_ssh.py "$WORK/gitui_ssh" "$ss_root/pty" "$ss_pty_bare" "$(ss_url_of "$ss_pty_bare")" \
            "$ss_fp" "$ss_root/other_host_key.pub" "$ss_port" 2>&1); then
            note "ssh pty: $(echo "$out" | grep -c '^ok') end-to-end checks passed under a real pty"
        else
            bad "ssh pty end-to-end" "$out"
        fi
    else
        bad "ssh: scripts/build-gitui.sh" "$(tail -5 "$ss_root/gitui_build.log")"
    fi
fi

if [ "${ss_up:-0}" = 1 ] && [ "$fail" -gt "${ss_fail0:-$fail}" ]; then
    printf 'ssh diagnostics: sshd alive=%s, log tail:\n' "$(kill -0 "$ss_pid" 2>/dev/null && echo yes || echo no)"
    tail -25 "$ss_root/sshd.log" | sed 's/^/     /'
fi
ss_stop
[ -n "${ss_watch:-}" ] && kill "$ss_watch" >/dev/null 2>&1
fi
