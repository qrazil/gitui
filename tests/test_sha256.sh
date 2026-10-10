#!/usr/bin/env bash
# SHA-256 repositories (`git init --object-format=sha256`), against real git.
#
# Sourced from `test.sh`: no `set`, no `cd`, no `trap` here, and `$WORK`,
# `build`, `note`, `bad` and the counters are test.sh's.
#
# These repositories are always SHA-256, whatever `TEST_HASH` says, because
# `--object-format` is spelled out. `TEST_HASH=sha256 bash tests/test.sh` is the
# other half: it makes every fixture of every family a SHA-256 one. What is
# here is what only a SHA-256 repository (or two, or one of each) can say: the
# object store, packs and `.idx`, the index and refs written by this program
# and then judged by `git fsck --strict`, the commands, the refusals, and a
# push and a pull between repositories of the same and of different formats.
#
# Every date, name and email is fixed, so the same call builds the same
# repository each time.

sh2="$WORK/sha256"
mkdir -p "$sh2"

sh2_env() {
    env GIT_AUTHOR_NAME=Sha_Tester GIT_AUTHOR_EMAIL=s@example.com \
        GIT_COMMITTER_NAME=Sha_Tester GIT_COMMITTER_EMAIL=s@example.com \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$@"
}

# sh2_commit <n> -- one commit touching two files and a subdirectory, a second apart
sh2_commit() {
    printf 'line %d of file A\nsome shared boilerplate text goes here for delta compression\n' "$1" >>a.txt
    printf 'line %d of file B\nsome shared boilerplate text goes here for delta compression\n' "$1" >>b.txt
    mkdir -p dir/sub
    printf 'content %d\n' "$1" >"dir/sub/f$1.txt"
    git add -A
    GIT_AUTHOR_DATE="17100000$((10 + $1)) +0000" GIT_COMMITTER_DATE="17100000$((10 + $1)) +0000" \
        git commit -q -m "commit $1"
}

# sh2_build <dir> <format> [<count>] -- a repository with history, a symlink, an
# executable, an annotated tag and a branch
sh2_build() {
    local dir=$1 fmt=$2 count=${3:-12} i=1
    rm -rf "$dir"
    git init -q -b main --object-format="$fmt" "$dir" || return 1
    cd "$dir" || return 1
    while [ "$i" -le "$count" ]; do
        sh2_commit "$i"
        i=$((i + 1))
    done
    ln -s a.txt link.txt
    printf '#!/bin/sh\necho hi\n' >run.sh
    chmod +x run.sh
    git add -A
    GIT_AUTHOR_DATE="1710000100 +0000" GIT_COMMITTER_DATE="1710000100 +0000" git commit -q -m "links"
    git branch side main~3
    GIT_COMMITTER_DATE="1710000200 +0000" git tag -a v1 -m "annotated" main~2
    git tag light main~1
}

sh2_run() { (sh2_env bash -c 'set -e; '"$(declare -f sh2_commit sh2_build)"'; sh2_build "$@"' _ "$@"); }

# --- fixtures: loose, packed with offset deltas, packed with ref deltas ---------

sh2_loose="$sh2/loose"
sh2_packed="$sh2/packed"
sh2_refdelta="$sh2/refdelta"
sh2_ok=1
sh2_run "$sh2_loose" sha256 >"$sh2/loose.log" 2>&1 || sh2_ok=0
sh2_run "$sh2_packed" sha256 >"$sh2/packed.log" 2>&1 || sh2_ok=0
sh2_env git -C "$sh2_packed" repack -adq >>"$sh2/packed.log" 2>&1 || sh2_ok=0
sh2_env git -C "$sh2_packed" pack-refs --all >>"$sh2/packed.log" 2>&1 || sh2_ok=0
rm -rf "$sh2_refdelta"
cp -r "$sh2_packed" "$sh2_refdelta" 2>/dev/null || sh2_ok=0
(
    set -e
    cd "$sh2_refdelta"
    sh2_env git rev-list --objects --all | sh2_env git pack-objects --no-delta-base-offset -q .git/objects/pack/refdelta
    rm -f .git/objects/pack/pack-*
) >"$sh2/refdelta.log" 2>&1 || sh2_ok=0
if [ "$sh2_ok" = 1 ] && [ "$(sh2_env git -C "$sh2_loose" rev-parse --show-object-format)" = sha256 ]; then
    note "sha256: fixtures built (loose; repacked with OBJ_OFS_DELTA and packed-refs; OBJ_REF_DELTA)"
else
    bad "sha256 fixtures" "$(tail -3 "$sh2/loose.log")" "$(tail -3 "$sh2/packed.log")" "$(tail -3 "$sh2/refdelta.log")"
fi
for sh2_repo in "$sh2_loose" "$sh2_packed" "$sh2_refdelta"; do
    sh2_fsck=$(sh2_env git -C "$sh2_repo" fsck --strict 2>&1 | grep -v '^Checking\|^notice\|^dangling')
    [ -z "$sh2_fsck" ] || bad "sha256 fixture $(basename "$sh2_repo") is not fsck-clean" "$sh2_fsck"
done
sh2_packs=$(ls "$sh2_packed/.git/objects/pack" | grep -c '\.idx$')
sh2_deltas=$(sh2_env git -C "$sh2_packed" verify-pack -v "$sh2_packed"/.git/objects/pack/*.idx 2>/dev/null | awk 'NF >= 7 && $1 ~ /^[0-9a-f]+$/ && length($1) == 64 {n++} END {print n + 0}')
[ "$sh2_packs" -ge 1 ] && [ "$sh2_deltas" -ge 5 ] && note "sha256: the packed fixture has $sh2_packs pack with $sh2_deltas deltified objects, 64-digit names in its .idx" ||
    bad "sha256 packed fixture shape" "packs=$sh2_packs deltified=$sh2_deltas"

# --- objects against the Python reader, and the commands against git -------------

if build t_object; then
    for sh2_repo in "$sh2_loose" "$sh2_packed" "$sh2_refdelta"; do
        "$WORK/t_object" "$sh2_repo/.git" >"$sh2/obj.got" 2>"$sh2/obj.err"
        python3 tests/oracles/oracle_object.py "$sh2_repo/.git" >"$sh2/obj.want" 2>"$sh2/obj.oracle"
        if [ -s "$sh2/obj.want" ] && cmp -s "$sh2/obj.got" "$sh2/obj.want"; then
            note "sha256 objects: $(wc -l <"$sh2/obj.got" | tr -d ' ') lines match the Python reader on $(basename "$sh2_repo")"
        else
            bad "sha256 objects on $(basename "$sh2_repo")" "$(diff "$sh2/obj.got" "$sh2/obj.want" | head -8)" "$(head -3 "$sh2/obj.err")" "$(head -3 "$sh2/obj.oracle")"
        fi
    done
fi
if build git; then
    for sh2_repo in "$sh2_loose" "$sh2_packed" "$sh2_refdelta"; do
        if sh2_out=$(bash scripts/compare.sh "$WORK/git" "$sh2_repo" "$sh2/cmp" 2>&1); then
            note "sha256 commands on $(basename "$sh2_repo"): ${sh2_out## }"
        else
            bad "sha256 commands on $(basename "$sh2_repo")" "$sh2_out"
        fi
    done
fi

# --- the write path: objects, index, refs, status -----------------------------------

sh2_w="$sh2/write"
sh2_run "$sh2_w" sha256 3 >"$sh2/w.log" 2>&1 || bad "sha256 write fixture" "$(tail -3 "$sh2/w.log")"
sh2_head=$(sh2_env git -C "$sh2_w" rev-parse HEAD)

if build t_write_object; then
    if "$WORK/t_write_object" "$sh2_w/.git" >"$sh2/wobj.out" 2>"$sh2/wobj.err"; then
        sh2_blob=$(sed -n 1p "$sh2/wobj.out")
        sh2_tree=$(sed -n 2p "$sh2/wobj.out")
        sh2_commit_id=$(sed -n 3p "$sh2/wobj.out")
        sh2_fsck=$(sh2_env git -C "$sh2_w" fsck --strict 2>&1 | grep -v '^Checking\|^notice\|^dangling')
        if [ "${#sh2_blob}" = 64 ] && [ "$(sh2_env git -C "$sh2_w" cat-file -p "$sh2_blob")" = "hello from the write path" ] &&
            [ "$(sh2_env git -C "$sh2_w" cat-file -t "$sh2_tree")" = tree ] && [ "$(sh2_env git -C "$sh2_w" cat-file -t "$sh2_commit_id")" = commit ] &&
            [ "$(sh2_env git -C "$sh2_w" hash-object --stdin <<<'hello from the write path')" = "$sh2_blob" ] && [ -z "$sh2_fsck" ]; then
            note "sha256 object writing: blob/tree/commit are 64-digit names git reads back; its hash-object agrees; fsck --strict clean"
        else
            bad "sha256 object writing" "$(cat "$sh2/wobj.out")" "$sh2_fsck"
        fi
    else
        bad "sha256 t_write_object" "$(cat "$sh2/wobj.err")"
    fi
fi

if build t_index_read; then
    "$WORK/t_index_read" "$sh2_w/.git" >"$sh2/ixread.got" 2>"$sh2/ixread.err"
    sh2_env git -C "$sh2_w" ls-files --stage >"$sh2/ixread.want"
    if [ -s "$sh2/ixread.want" ] && cmp -s "$sh2/ixread.got" "$sh2/ixread.want"; then
        note "sha256 index reading (32-octet entry ids, 32-octet checksum) matches 'git ls-files --stage' byte for byte"
    else
        bad "sha256 index reading" "$(diff "$sh2/ixread.got" "$sh2/ixread.want" | head -6)" "$(cat "$sh2/ixread.err")"
    fi
fi
if build t_index_rewrite; then
    sh2_before=$(sh2_env git -C "$sh2_w" ls-files --stage)
    if "$WORK/t_index_rewrite" "$sh2_w/.git" >/dev/null 2>"$sh2/ixrw.err" && [ "$(sh2_env git -C "$sh2_w" ls-files --stage)" = "$sh2_before" ] &&
        sh2_env git -C "$sh2_w" status --short >/dev/null 2>&1; then
        note "sha256 index writing: the re-encoded index is accepted by git and lists the same entries"
    else
        bad "sha256 index writing" "$(cat "$sh2/ixrw.err")"
    fi
fi
if build t_index_stage; then
    printf 'brand new content\n' >"$sh2_w/staged.txt"
    sh2_want=$(sh2_env git -C "$sh2_w" hash-object "$sh2_w/staged.txt")
    if "$WORK/t_index_stage" "$sh2_w/.git" "$sh2_w" staged.txt >"$sh2/ixstage.out" 2>"$sh2/ixstage.err" &&
        [ "$(sh2_env git -C "$sh2_w" ls-files --stage -- staged.txt)" = "$(printf '100644 %s 0\tstaged.txt' "$sh2_want")" ] &&
        [ "$(sh2_env git -C "$sh2_w" status --short -- staged.txt)" = "A  staged.txt" ]; then
        note "sha256 index staging: the new entry has git's own 64-digit blob name and a clean 'A ' status"
    else
        bad "sha256 index staging" "$(cat "$sh2/ixstage.out")" "$(cat "$sh2/ixstage.err")" "want $sh2_want"
    fi
fi
if build t_status; then
    printf 'changed\n' >>"$sh2_w/a.txt"
    rm -f "$sh2_w/b.txt"
    printf 'loose\n' >"$sh2_w/untracked.txt"
    "$WORK/t_status" "$sh2_w/.git" "$sh2_w" >"$sh2/status.got" 2>"$sh2/status.err"
    sh2_env git -C "$sh2_w" status --short >"$sh2/status.want"
    if [ -s "$sh2/status.want" ] && cmp -s "$sh2/status.got" "$sh2/status.want"; then
        note "sha256 status: staged, unstaged, deleted and untracked match 'git status --short'"
    else
        bad "sha256 status" "$(diff "$sh2/status.got" "$sh2/status.want")" "$(cat "$sh2/status.err")"
    fi
    sh2_env git -C "$sh2_w" checkout -q -- a.txt b.txt
    rm -f "$sh2_w/untracked.txt"
fi
if build t_write_refs; then
    "$WORK/t_write_refs" "$sh2_w/.git" "$sh2_commit_id" "$sh2_head" >"$sh2/wrefs.out" 2>"$sh2/wrefs.err"
    sh2_ok=1
    for sh2_line in "update-plain ok" "symbolic-head ok" "cas-right ok" "detached-head ok" "cas-create ok"; do
        grep -qx "$sh2_line" "$sh2/wrefs.out" || sh2_ok=0
    done
    grep -q '^cas-wrong err' "$sh2/wrefs.out" || sh2_ok=0
    [ "$(sh2_env git -C "$sh2_w" rev-parse refs/heads/newbranch)" = "$sh2_head" ] || sh2_ok=0
    [ "$(sh2_env git -C "$sh2_w" rev-parse refs/heads/fresh)" = "$sh2_commit_id" ] || sh2_ok=0
    [ "$(cat "$sh2_w/.git/HEAD")" = "$sh2_commit_id" ] || sh2_ok=0
    if [ "$sh2_ok" = 1 ]; then
        note "sha256 ref writing: update, update_symbolic and compare-and-swap with 64-digit names agree with git"
    else
        bad "sha256 ref writing" "$(cat "$sh2/wrefs.out")" "$(cat "$sh2/wrefs.err")"
    fi
    sh2_env git -C "$sh2_w" symbolic-ref HEAD refs/heads/main 2>/dev/null
fi

# --- a pack written by this program, judged by git index-pack, and read back --------

if build t_packwrite; then
    sh2_idx="$sh2/idx.git"
    rm -rf "$sh2_idx"
    git init -q --bare --object-format=sha256 "$sh2_idx"
    if "$WORK/t_packwrite" build "$sh2_loose/.git" "$sh2/all.pack" >"$sh2/pw.out" 2>"$sh2/pw.err" &&
        sh2_env git -C "$sh2_idx" index-pack --strict --stdin <"$sh2/all.pack" >/dev/null 2>"$sh2/pw.idx"; then
        sh2_want=$(sh2_env git -C "$sh2_loose" cat-file --batch-all-objects --batch-check='%(objectname)' | wc -l | tr -d ' ')
        sh2_got=$(sh2_env git -C "$sh2_idx" count-objects -v | awk '/^in-pack:/ {print $2}')
        sh2_bad=0
        for sh2_id in $(sh2_env git -C "$sh2_loose" cat-file --batch-all-objects --batch-check='%(objectname)' | head -40); do
            [ "$("$WORK/t_packwrite" stat "$sh2_idx" "$sh2_id" 2>&1)" = "$(sh2_env git -C "$sh2_loose" cat-file -t "$sh2_id") $(sh2_env git -C "$sh2_loose" cat-file -s "$sh2_id")" ] || sh2_bad=$((sh2_bad + 1))
        done
        if [ "$sh2_got" = "$sh2_want" ] && [ "$sh2_bad" = 0 ]; then
            note "sha256 packwrite: git index-pack --strict accepts a pack of every object ($sh2_got), and 40 read back through the new .idx"
        else
            bad "sha256 packwrite" "indexed $sh2_got of $sh2_want" "unreadable: $sh2_bad"
        fi
    else
        bad "sha256 packwrite build / index-pack" "$(cat "$sh2/pw.err")" "$(cat "$sh2/pw.idx" 2>/dev/null)"
    fi
fi

# --- what is refused ----------------------------------------------------------------

if [ -x "$WORK/git" ]; then
    sh2_x="$sh2/refuse"
    rm -rf "$sh2_x"
    cp -r "$sh2_loose" "$sh2_x"
    sh2_cfg=$(cat "$sh2_x/.git/config")
    sh2_refuses() { # <label> <expected text> -- `ourgit -refs` must fail naming it
        sh2_out=$("$WORK/git" --git-dir "$sh2_x/.git" -refs 2>&1)
        sh2_rc=$?
        case "$sh2_out" in
            *"$2"*) [ "$sh2_rc" != 0 ] && note "sha256 refusal: $1" || bad "sha256 refusal: $1" "exit status 0" ;;
            *) bad "sha256 refusal: $1" "$sh2_out" ;;
        esac
        printf '%s\n' "$sh2_cfg" >"$sh2_x/.git/config"
    }
    sh2_env git -C "$sh2_x" config extensions.refStorage reftable
    sh2_refuses "extensions.refStorage is refused, by name" "refstorage"
    sh2_env git -C "$sh2_x" config extensions.compatObjectFormat sha1
    sh2_refuses "extensions.compatObjectFormat is refused, by name" "compatobjectformat"
    sh2_env git -C "$sh2_x" config extensions.partialClone origin
    sh2_refuses "extensions.partialClone is refused, by name" "partialclone"
    sh2_env git -C "$sh2_x" config extensions.objectFormat sha512
    sh2_refuses "an object format that is neither sha1 nor sha256" "sha512"
    sh2_env git -C "$sh2_x" config core.repositoryFormatVersion 0
    sh2_refuses "objectFormat in a version 0 repository, as git dies on it" "v1-only extension"
    sh2_env git -C "$sh2_x" config core.repositoryFormatVersion 2
    sh2_refuses "a repository format version above 1" "version 2"
    printf '%s\n' "$sh2_cfg" >"$sh2_x/.git/config"
    sh2_env git -C "$sh2_x" config extensions.preciousObjects true
    if [ "$("$WORK/git" --git-dir "$sh2_x/.git" -rev-parse HEAD 2>&1)" = "$(sh2_env git -C "$sh2_x" rev-parse HEAD)" ]; then
        note "sha256: extensions.preciousObjects is accepted (this program never prunes)"
    else
        bad "sha256: preciousObjects" "$("$WORK/git" --git-dir "$sh2_x/.git" -rev-parse HEAD 2>&1)"
    fi
fi

# --- between repositories: push and pull, same format and different -----------------
#
# A real `git http-backend` behind a small CGI server, one repository of each
# format as the remote. The client's own format must be the server's: a SHA-1
# client talking to a SHA-256 server, and the other way round, is refused with
# a message about the object format and changes nothing on either side.

sh2_backend="$(git --exec-path)/git-http-backend"
if command -v python3 >/dev/null 2>&1 && [ -x "$sh2_backend" ] && build t_push && build t_pull; then
    sh2_srv="$sh2/srv"
    mkdir -p "$sh2_srv/www/cgi-bin"
    for sh2_fmt in sha1 sha256; do
        rm -rf "$sh2_srv/$sh2_fmt"
        mkdir -p "$sh2_srv/$sh2_fmt"
        git init -q --bare -b main --object-format="$sh2_fmt" "$sh2_srv/$sh2_fmt/repo.git"
        git -C "$sh2_srv/$sh2_fmt/repo.git" config http.receivepack true
        cat >"$sh2_srv/www/cgi-bin/backend-$sh2_fmt" <<WRAP
#!/bin/sh
export GIT_PROJECT_ROOT="$sh2_srv/$sh2_fmt"
export GIT_HTTP_EXPORT_ALL=1
exec "$sh2_backend"
WRAP
        chmod +x "$sh2_srv/www/cgi-bin/backend-$sh2_fmt"
    done
    cat >"$sh2_srv/serve.py" <<'PY'
import http.server
import os
import sys

port = int(sys.argv[1])
os.chdir(sys.argv[2])


class Handler(http.server.CGIHTTPRequestHandler):
    cgi_directories = ["/cgi-bin"]

    def log_message(self, fmt, *args):
        pass


http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
    sh2_port=$((20000 + (RANDOM % 20000)))
    python3 "$sh2_srv/serve.py" "$sh2_port" "$sh2_srv/www" >"$sh2/serve.log" 2>&1 &
    sh2_server_pid=$!
    trap 'kill ${hf_server_pid:+"$hf_server_pid"} ${hf_proxy_pid:+"$hf_proxy_pid"} ${pp_server_pid:+"$pp_server_pid"} ${pp_aserver_pid:+"$pp_aserver_pid"} "$sh2_server_pid" >/dev/null 2>&1; wait ${hf_server_pid:+"$hf_server_pid"} ${hf_proxy_pid:+"$hf_proxy_pid"} ${pp_server_pid:+"$pp_server_pid"} ${pp_aserver_pid:+"$pp_aserver_pid"} "$sh2_server_pid" 2>/dev/null; rm -rf "$WORK"' EXIT
    sh2_up=0
    for sh2_try in $(seq 1 50); do
        if (exec 3<>"/dev/tcp/127.0.0.1/$sh2_port") 2>/dev/null; then
            sh2_up=1
            break
        fi
        sleep 0.1
    done
    sh2_url() { echo "http://127.0.0.1:$sh2_port/cgi-bin/backend-$1/repo.git"; }

    if [ "$sh2_up" = 1 ]; then
        sh2_c1="$sh2/client-sha1"
        sh2_run "$sh2_c1" sha1 4 >"$sh2/c1.log" 2>&1 || bad "sha1 client fixture" "$(tail -3 "$sh2/c1.log")"
        sh2_c2="$sh2/client-sha256"
        sh2_run "$sh2_c2" sha256 4 >"$sh2/c2.log" 2>&1 || bad "sha256 client fixture" "$(tail -3 "$sh2/c2.log")"

        # push: same format, then a second push of new commits
        if "$WORK/t_push" push "$sh2_c2/.git" "$(sh2_url sha256)" refs/heads/main >"$sh2/p1.out" 2>"$sh2/p1.err" &&
            [ "$(git -C "$sh2_srv/sha256/repo.git" rev-parse refs/heads/main)" = "$(git -C "$sh2_c2" rev-parse main)" ] &&
            sh2_env git -C "$sh2_srv/sha256/repo.git" fsck --strict >"$sh2/p1.fsck" 2>&1; then
            note "sha256 push: a first push to an empty SHA-256 server sets the ref to the client's 64-digit tip; the server's fsck --strict is clean"
        else
            bad "sha256 push to an empty server" "$(cat "$sh2/p1.out")" "$(cat "$sh2/p1.err")" "$(tail -3 "$sh2/p1.fsck" 2>/dev/null)"
        fi
        (cd "$sh2_c2" && sh2_env bash -c 'printf more >>a.txt; git commit -qam "after the first push"') >/dev/null 2>&1
        if "$WORK/t_push" push "$sh2_c2/.git" "$(sh2_url sha256)" refs/heads/main >"$sh2/p2.out" 2>"$sh2/p2.err" &&
            [ "$(git -C "$sh2_srv/sha256/repo.git" rev-parse refs/heads/main)" = "$(git -C "$sh2_c2" rev-parse main)" ] &&
            sh2_env git -C "$sh2_srv/sha256/repo.git" fsck --strict >"$sh2/p2.fsck" 2>&1 &&
            [ "$(git -C "$sh2_srv/sha256/repo.git" rev-list --count main)" = "$(git -C "$sh2_c2" rev-list --count main)" ]; then
            note "sha256 push: new commits fast-forward the server's ref; its history and fsck --strict agree"
        else
            bad "sha256 push of new commits" "$(cat "$sh2/p2.out")" "$(cat "$sh2/p2.err")" "$(tail -3 "$sh2/p2.fsck" 2>/dev/null)"
        fi

        # push: the formats differ, in both directions
        sh2_before1=$(git -C "$sh2_srv/sha256/repo.git" for-each-ref | wc -l | tr -d ' ')
        if "$WORK/t_push" push "$sh2_c1/.git" "$(sh2_url sha256)" refs/heads/main >"$sh2/p3.out" 2>"$sh2/p3.err"; then
            bad "sha256 push: a SHA-1 client was allowed to push to a SHA-256 server" "$(cat "$sh2/p3.out")"
        elif grep -qi 'object format' "$sh2/p3.err" && [ "$(git -C "$sh2_srv/sha256/repo.git" for-each-ref | wc -l | tr -d ' ')" = "$sh2_before1" ]; then
            note "sha256 push: a SHA-1 repository pushing to a SHA-256 server is refused ($(head -1 "$sh2/p3.err")), the server untouched"
        else
            bad "sha256 push: SHA-1 to SHA-256 refusal" "$(cat "$sh2/p3.err")"
        fi
        if "$WORK/t_push" push "$sh2_c2/.git" "$(sh2_url sha1)" refs/heads/main >"$sh2/p4.out" 2>"$sh2/p4.err"; then
            bad "sha256 push: a SHA-256 client was allowed to push to a SHA-1 server" "$(cat "$sh2/p4.out")"
        elif grep -qi 'object format' "$sh2/p4.err" && [ "$(git -C "$sh2_srv/sha1/repo.git" for-each-ref | wc -l | tr -d ' ')" = 0 ]; then
            note "sha256 push: a SHA-256 repository pushing to a SHA-1 server is refused ($(head -1 "$sh2/p4.err")), the server untouched"
        else
            bad "sha256 push: SHA-256 to SHA-1 refusal" "$(cat "$sh2/p4.err")"
        fi

        # pull: a SHA-256 clone one commit behind the server catches up; the others are refused
        sh2_pull="$sh2/pull-sha256"
        rm -rf "$sh2_pull"
        sh2_env git clone -q "$(sh2_url sha256)" "$sh2_pull" >"$sh2/clone.log" 2>&1
        if [ "$(sh2_env git -C "$sh2_pull" rev-parse --show-object-format 2>/dev/null)" = sha256 ]; then
            note "sha256 clone: real git clones the SHA-256 server and takes its format from the remote's advertisement"
        else
            bad "sha256 clone with real git" "$(tail -3 "$sh2/clone.log")"
        fi
        (cd "$sh2_c2" && sh2_env bash -c 'printf again >>b.txt; git commit -qam "one more"; git tag -a v2 -m t') >/dev/null 2>&1
        "$WORK/t_push" push "$sh2_c2/.git" "$(sh2_url sha256)" refs/heads/main >/dev/null 2>&1
        sh2_gd="$sh2_pull/.git"
        if "$WORK/t_pull" pull "$sh2_gd" "$sh2_pull" "$(sh2_url sha256)" >"$sh2/pl1.out" 2>"$sh2/pl1.err" &&
            [ "$(git -C "$sh2_pull" rev-parse HEAD)" = "$(git -C "$sh2_srv/sha256/repo.git" rev-parse main)" ] &&
            sh2_env git -C "$sh2_pull" fsck --strict >"$sh2/pl1.fsck" 2>&1 && [ -z "$(git -C "$sh2_pull" status --short)" ]; then
            note "sha256 pull: a fast-forward from a SHA-256 server (64-digit wants and haves, 32-octet pack trailer); fsck --strict and status are clean"
        else
            bad "sha256 pull" "$(cat "$sh2/pl1.out")" "$(cat "$sh2/pl1.err")" "$(tail -3 "$sh2/pl1.fsck" 2>/dev/null)"
        fi
        sh2_head_before=$(git -C "$sh2_pull" rev-parse HEAD)
        if "$WORK/t_pull" pull "$sh2_gd" "$sh2_pull" "$(sh2_url sha1)" >"$sh2/pl2.out" 2>"$sh2/pl2.err"; then
            bad "sha256 pull: a SHA-256 client was allowed to pull from a SHA-1 server" "$(cat "$sh2/pl2.out")"
        elif grep -qi 'object format\|no branch\|no commits' "$sh2/pl2.err" && [ "$(git -C "$sh2_pull" rev-parse HEAD)" = "$sh2_head_before" ]; then
            note "sha256 pull: a SHA-256 repository pulling from a SHA-1 server is refused ($(head -1 "$sh2/pl2.err")), nothing changed"
        else
            bad "sha256 pull: SHA-256 from SHA-1 refusal" "$(cat "$sh2/pl2.err")"
        fi
        # a SHA-1 server with a branch of the same name, so only the format can refuse it
        "$WORK/t_push" push "$sh2_c1/.git" "$(sh2_url sha1)" refs/heads/main >/dev/null 2>&1
        if "$WORK/t_pull" pull "$sh2_gd" "$sh2_pull" "$(sh2_url sha1)" >"$sh2/pl3.out" 2>"$sh2/pl3.err"; then
            bad "sha256 pull: a SHA-256 client pulled from a SHA-1 server that has the branch" "$(cat "$sh2/pl3.out")"
        elif grep -qi 'object format' "$sh2/pl3.err" && [ "$(git -C "$sh2_pull" rev-parse HEAD)" = "$sh2_head_before" ]; then
            note "sha256 pull: with the branch present on a SHA-1 server only the format refuses it ($(head -1 "$sh2/pl3.err"))"
        else
            bad "sha256 pull: SHA-256 from SHA-1 (branch present)" "$(cat "$sh2/pl3.err")"
        fi
        sh2_p1="$sh2/pull-sha1"
        rm -rf "$sh2_p1"
        sh2_env git clone -q "$(sh2_url sha1)" "$sh2_p1" >/dev/null 2>&1
        if "$WORK/t_pull" pull "$sh2_p1/.git" "$sh2_p1" "$(sh2_url sha256)" >"$sh2/pl4.out" 2>"$sh2/pl4.err"; then
            bad "sha256 pull: a SHA-1 client was allowed to pull from a SHA-256 server" "$(cat "$sh2/pl4.out")"
        elif grep -qi 'object format' "$sh2/pl4.err"; then
            note "sha256 pull: a SHA-1 repository pulling from a SHA-256 server is refused ($(head -1 "$sh2/pl4.err"))"
        else
            bad "sha256 pull: SHA-1 from SHA-256 refusal" "$(cat "$sh2/pl4.err")"
        fi
    else
        bad "sha256 servers did not start" "$(cat "$sh2/serve.log")"
    fi
else
    note "sha256 push/pull: python3 or git-http-backend missing; server-backed checks skipped"
fi
