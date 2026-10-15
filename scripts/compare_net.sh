#!/usr/bin/env bash
# The network commands of `1git` (`clone`, `fetch`, `pull`, `push`, `remote`,
# `ls-remote`) beside the real `git`, against a real smart-HTTP server on
# localhost: `tests/net_serve.py`, which runs `git http-backend` over a
# disposable bare repository. Same method as compare_merge.sh: a fixture is
# built twice from the same script with fixed identities and dates, each side
# talks to its own copy of the remote, and after the commands under test both
# sides are dumped and compared.
#
#   bash scripts/compare_net.sh <1git-binary> [workdir] [group...]
#
# groups: ls fetch clone pull push remote auth proto  (default: all)
#
# In a case's script `G <args>` is real `git` on one side and `1git` on the
# other; `P <args>` is real git in a separate "pusher" clone of the remote
# (how the remote moves on between two calls), `$URL` is the remote's URL.
# Compared: stdout, stderr (with the port and repository names normalised)
# and exit status of every `G`; then the local repository's refs, HEAD,
# config, reflogs, shallow file, FETCH_HEAD, object ids and work tree, and the
# remote's refs and `fsck`. Credentials are throwaway values of this script.
set -uo pipefail
exec 2> >(grep -v 'templates not found' >&2)

OURS=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${2:-$(mktemp -d)}
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
shift
shift || true
GROUPS_WANTED=${*:-ls fetch clone pull push remote auth proto}

export LC_ALL=C TZ=UTC GIT_DEFAULT_HASH=sha1
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME="Ada Author" GIT_AUTHOR_EMAIL="ada@example.com"
export GIT_COMMITTER_NAME="Cy Committer" GIT_COMMITTER_EMAIL="cy@example.org"
export GIT_AUTHOR_DATE="1800000000 +0000" GIT_COMMITTER_DATE="1800000000 +0000"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE NO_COLOR GIT_ASKPASS SSH_ASKPASS
umask 022
CLOCK=1800000000
tick() {
    CLOCK=$((CLOCK + 60))
    export GIT_AUTHOR_DATE="$CLOCK +0000" GIT_COMMITTER_DATE="$CLOCK +0000"
}

# --- the server ------------------------------------------------------------------------

SRV=$WORK/srv
mkdir -p "$SRV/repos/ra" "$SRV/repos/rb"
ln -sfn "$SRV/repos/ra" "$SRV/cur"
start_server() {
    local auth=${1:-}
    : > "$SRV/log"
    python3 "$HERE/../tests/net_serve.py" "$SRV/cur" "$SRV/log" $auth > "$SRV/ready" &
    SERVER_PID=$!
    local i
    for i in $(seq 100); do
        grep -q '^ready' "$SRV/ready" 2> /dev/null && break
        sleep 0.1
    done
    PORT=$(sed -n 's/^ready //p' "$SRV/ready")
}
stop_server() {
    [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2> /dev/null
    wait "$SERVER_PID" 2> /dev/null
    SERVER_PID=
}
trap 'stop_server' EXIT
start_server

bad=0
n=0

# --- fixtures: each makes a bare repository at $1 ----------------------------------------

commit_in() { # <message> [file content]
    tick
    printf '%s\n' "${3:-$1}" >> "${2:-f.txt}"
    git add -A
    git commit -q -m "$1"
}

fx_basic() {
    local w=$WORK/fx-work
    rm -rf "$w" "$1"
    git init -q -b main "$w"
    (
        cd "$w" || exit 1
        mkdir -p .git/hooks
        commit_in c1
        commit_in c2
        git tag v1
        commit_in c3
        git tag -a v2 -m "annotated two"
        git checkout -q -b feature
        commit_in f1 g.txt
        git checkout -q main
        git update-ref refs/pull/1/head feature
        git clone -q --bare "$w" "$1"
        git -C "$1" symbolic-ref HEAD refs/heads/main
        git -C "$1" config receive.advertisePushOptions true
        mkdir -p "$1/hooks"
        cat > "$1/hooks/pre-receive" << 'HOOK'
#!/bin/sh
# prints the push options and refuses refs named deny*
i=0
while [ "$i" -lt "${GIT_PUSH_OPTION_COUNT:-0}" ]; do
    eval "v=\$GIT_PUSH_OPTION_$i"
    echo "push option: $v" >&2
    i=$((i + 1))
done
while read -r old new ref; do
    case "$ref" in
        refs/heads/deny*) echo "denied: $ref" >&2; exit 1 ;;
    esac
done
exit 0
HOOK
        chmod +x "$1/hooks/pre-receive"
    ) > /dev/null 2>&1
}

fx_empty() {
    rm -rf "$1"
    git init -q --bare -b main "$1" > /dev/null 2>&1
}

# --- the harness -------------------------------------------------------------------------

dump_local() {
    local repo=$1
    [ -d "$repo/w" ] && repo=$repo/w
    (
        cd "$repo" || exit 1
        local gd
        gd=$(git rev-parse --git-dir 2> /dev/null) || { echo "(no repository)"; exit 0; }
        echo "## refs"
        git for-each-ref
        echo "## HEAD"
        git symbolic-ref -q HEAD || true
        git rev-parse -q --verify HEAD || true
        echo "## config"
        git config --local --list | grep -v -E "^core\.(ignorecase|precomposeunicode)=" | LC_ALL=C sort
        echo "## logs"
        if [ -d "$gd/logs" ]; then
            (cd "$gd/logs" && find . -type f | LC_ALL=C sort | while read -r f; do echo "-- $f"; cat "$f"; done)
        fi
        echo "## packed-refs"
        cat "$gd/packed-refs" 2> /dev/null
        echo "## shallow"
        cat "$gd/shallow" 2> /dev/null
        echo "## FETCH_HEAD"
        cat "$gd/FETCH_HEAD" 2> /dev/null
        echo "## objects"
        git cat-file --batch-all-objects --batch-check 2>&1 | LC_ALL=C sort
        echo "## index"
        git ls-files -s 2> /dev/null
        echo "## tree"
        if [ "$(git rev-parse --is-bare-repository)" = false ]; then
            find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while read -r f; do
                printf '%s %s %s\n' "$(stat -c %a "$f")" "$f" "$(sha1sum < "$f" | cut -c1-12)"
            done
            echo "## status"
            git status --porcelain=v2 -b 2>&1
        fi
        echo "## fsck"
        git fsck --strict --no-dangling 2>&1 | head -5
    )
}

dump_remote() {
    (
        cd "$1" || exit 1
        echo "## remote refs"
        git for-each-ref
        git symbolic-ref -q HEAD || true
        echo "## remote fsck"
        git fsck --strict --no-dangling 2>&1 | head -5
    )
}

normalise() { # <file> <repo-name> <local-dir>
    sed -i.bak -e "s|127\.0\.0\.1:$PORT|HOST|g" -e "s|$3|LOCAL|g" "$1"; rm -f "$1.bak"
}

run_side() {
    local bin=$1 name=$2 fixture=$3 setup=$4 script=$5 log=$6
    : > "$log"
    : > "$log.err"
    local bare=$SRV/repos/$name/r.git
    rm -rf "$SRV/repos/$name"; mkdir -p "$SRV/repos/$name"
    ln -sfn "$SRV/repos/$name" "$SRV/cur"
    rm -rf "$bare" "$WORK/side-$name"
    "$fixture" "$bare"
    mkdir -p "$WORK/side-$name"
    (
        cd "$WORK/side-$name" || exit 1
        URL=http://127.0.0.1:$PORT/git/r.git
        NOPE=http://127.0.0.1:$PORT/git/nosuch.git
        export NOPE
        BARE=$bare
        PUSHER=$WORK/pusher-$name
        export URL BARE PUSHER
        P() { git -C "$PUSHER" "$@"; }
        rm -rf "$PUSHER"
        git clone -q "$bare" "$PUSHER" > /dev/null 2>&1
        git -C "$PUSHER" config user.name x > /dev/null
        mkdir -p "$PUSHER/.git/hooks"
        T=$(mktemp -d)
        G() {
            "$bin" "$@" > "$T/o" 2> "$T/e"
            local rc=$?
            sed -i.bak '/templates not found/d' "$T/e"; rm -f "$T/e.bak"
            { printf '$ %s\n' "$*"; cat "$T/o"; printf 'rc=%s\n' "$rc"; } >> "$log"
            { printf '$ %s\n' "$*"; cat "$T/e"; } >> "$log.err"
            return $rc
        }
        L() { git "$@"; }
        eval "$setup" > /dev/null 2>&1
        eval "$script"
        rm -rf "$T"
    ) > /dev/null 2>&1
}

# case_ <label> <fixture> <setup> <script>
case_() {
    local label=$1 fixture=$2 setup=$3 script=$4
    if [ -n "${ONLY:-}" ] && [[ "$label" != *"$ONLY"* ]]; then
        return 0
    fi
    n=$((n + 1))
    run_side git ra "$fixture" "$setup" "$script" "$WORK/log-a"
    run_side "$OURS" rb "$fixture" "$setup" "$script" "$WORK/log-b"
    local a=$WORK/side-ra b=$WORK/side-rb
    { dump_local "$a"; dump_remote "$SRV/repos/ra/r.git"; } > "$WORK/dump-a" 2>&1
    { dump_local "$b"; dump_remote "$SRV/repos/rb/r.git"; } > "$WORK/dump-b" 2>&1
    # `rebase` here prints no `Rebasing (n/m)` progress (docs/GIT-COMPAT.md)
    sed -i.bak 's/Rebasing ([0-9]*\/[0-9]*)\r\{0,1\}//' "$WORK/log-a.err" "$WORK/log-b.err"; rm -f "$WORK"/log-[ab].err.bak
    for f in log-a log-a.err dump-a; do normalise "$WORK/$f" ra "$a"; done
    for f in log-b log-b.err dump-b; do normalise "$WORK/$f" rb "$b"; done
    local failed=0
    if [ -n "${SHOW:-}" ]; then
        echo "=== $label"; echo "--- git"; cat "$WORK/log-a" "$WORK/log-a.err"; echo "--- ours"; cat "$WORK/log-b" "$WORK/log-b.err"
    fi
    if ! cmp -s "$WORK/log-a" "$WORK/log-b"; then
        failed=1
        printf '\033[31mdiffer\033[0m %s: stdout\n' "$label"
        diff "$WORK/log-a" "$WORK/log-b" | head -16 | sed 's/^/       /'
    fi
    if ! cmp -s "$WORK/log-a.err" "$WORK/log-b.err"; then
        failed=1
        printf '\033[31mdiffer\033[0m %s: stderr\n' "$label"
        diff "$WORK/log-a.err" "$WORK/log-b.err" | head -16 | sed 's/^/       /'
    fi
    if ! cmp -s "$WORK/dump-a" "$WORK/dump-b"; then
        failed=1
        printf '\033[31mdiffer\033[0m %s: state\n' "$label"
        diff "$WORK/dump-a" "$WORK/dump-b" | head -16 | sed 's/^/       /'
    fi
    [ $failed -eq 0 ] || bad=$((bad + 1))
}

wanted() {
    case " $GROUPS_WANTED " in *" $1 "*) return 0 ;; esac
    return 1
}

ADD_ORIGIN='git init -q -b main . && mkdir -p .git/hooks && git remote add origin "$URL"'
CLONE_FIRST='git clone -q "$URL" . && mkdir -p .git/hooks'

# --- fetch ----------------------------------------------------------------------------------

if wanted fetch; then
    case_ "fetch: first fetch, branches and tags" fx_basic "$ADD_ORIGIN" 'G fetch origin'
    case_ "fetch: again, nothing new" fx_basic "$ADD_ORIGIN" 'G fetch origin; G fetch origin; G fetch'
    case_ "fetch: fast-forward after the remote moved" fx_basic "$ADD_ORIGIN" '
        G fetch origin
        tick; P checkout -q main; printf "more\n" >> "$PUSHER/f.txt"; P commit -qam more; P push -q origin main
        G fetch origin'
    case_ "fetch: forced update is rejected, then forced with +" fx_basic "$ADD_ORIGIN" '
        G fetch origin
        tick; P checkout -q main; P commit -q --amend -m rewritten; P push -q -f origin main
        G fetch origin
        G fetch origin "+refs/heads/main:refs/remotes/origin/main"'
    case_ "fetch: --prune removes a deleted branch" fx_basic "$ADD_ORIGIN" '
        G fetch origin
        P push -q origin --delete feature
        G fetch origin
        G fetch --prune origin'
    case_ "fetch: --tags and --no-tags" fx_basic "$ADD_ORIGIN" 'G fetch --no-tags origin; G fetch --tags origin'
    case_ "fetch: a branch by name (FETCH_HEAD, opportunistic tracking ref)" fx_basic "$ADD_ORIGIN" 'G fetch origin feature'
    case_ "fetch: refspec into a local branch and pull refs" fx_basic "$ADD_ORIGIN" '
        G fetch origin main:refs/heads/copy
        G fetch origin "refs/pull/*:refs/remotes/pr/*"'
    case_ "fetch: a tag by name" fx_basic "$ADD_ORIGIN" 'G fetch origin tag v1'
    case_ "fetch: by URL, no remote configured" fx_basic 'git init -q -b main . && mkdir -p .git/hooks' 'G fetch "$URL"; G fetch "$URL" main'
    case_ "fetch: missing remote ref" fx_basic "$ADD_ORIGIN" 'G fetch origin nosuchbranch'
    case_ "fetch: empty remote" fx_empty "$ADD_ORIGIN" 'G fetch origin'
    case_ "fetch: --depth then --unshallow" fx_basic "$ADD_ORIGIN" 'G fetch --depth 1 origin main; G fetch --depth 2 origin main; G fetch --unshallow origin main'
    case_ "fetch: --all" fx_basic "$ADD_ORIGIN" 'G fetch --all'
    case_ "fetch: into the current branch is refused" fx_basic "$ADD_ORIGIN" 'git checkout -q -b main2; G fetch origin main:main2'
fi

# --- clone ----------------------------------------------------------------------------------

if wanted clone; then
    case_ "clone: default" fx_basic "" 'G clone "$URL" w'
    case_ "clone: into a named directory, derived name" fx_basic "" 'G clone "$URL"; G clone "$URL" other/dir'
    case_ "clone: --bare" fx_basic "" 'G clone --bare "$URL" w'
    case_ "clone: -b branch" fx_basic "" 'G clone -b feature "$URL" w'
    case_ "clone: -b tag (detached)" fx_basic "" 'G clone -b v1 "$URL" w'
    case_ "clone: -b missing" fx_basic "" 'G clone -b nosuch "$URL" w'
    case_ "clone: --single-branch" fx_basic "" 'G clone --single-branch "$URL" w'
    case_ "clone: --single-branch -b feature" fx_basic "" 'G clone --single-branch -b feature "$URL" w'
    case_ "clone: --depth 1" fx_basic "" 'G clone --depth 1 "$URL" w'
    case_ "clone: --depth 2" fx_basic "" 'G clone --depth 2 "$URL" w'
    case_ "clone: --origin and --no-tags" fx_basic "" 'G clone -o up --no-tags "$URL" w'
    case_ "clone: --no-checkout" fx_basic "" 'G clone -n "$URL" w'
    case_ "clone: -q" fx_basic "" 'G clone -q "$URL" w'
    case_ "clone: empty repository" fx_empty "" 'G clone "$URL" w'
    case_ "clone: destination exists" fx_basic "" 'mkdir w; echo x > w/f; G clone "$URL" w'
    case_ "clone: not found" fx_basic "" 'G clone "$NOPE" w'
    case_ "clone: -c config" fx_basic "" 'G clone -c user.name=zed -c core.autocrlf=false "$URL" w'
    case_ "clone: then fetch and log work" fx_basic "" 'G clone "$URL" w; cd w; tick; P checkout -q main; printf "x\n" >> "$PUSHER/f.txt"; P commit -qam x; P push -q origin main; G fetch; L log --oneline origin/main'
fi

# --- ls-remote ------------------------------------------------------------------------------

if wanted ls; then
    case_ "ls-remote: a URL" fx_basic "" 'G ls-remote "$URL"'
    case_ "ls-remote: a named remote" fx_basic "$ADD_ORIGIN" 'G ls-remote origin; G ls-remote'
    case_ "ls-remote: --heads --tags --refs" fx_basic "" 'G ls-remote --heads "$URL"; G ls-remote --tags "$URL"; G ls-remote --refs "$URL"; G ls-remote -h -t "$URL"'
    case_ "ls-remote: patterns" fx_basic "" 'G ls-remote "$URL" main; G ls-remote "$URL" "refs/heads/*"; G ls-remote "$URL" "v*" nosuch; G ls-remote "$URL" HEAD'
    case_ "ls-remote: --symref" fx_basic "" 'G ls-remote --symref "$URL"; G ls-remote --symref "$URL" HEAD'
    case_ "ls-remote: --exit-code" fx_basic "" 'G ls-remote --exit-code "$URL" nosuch; G ls-remote --exit-code "$URL" main'
    case_ "ls-remote: empty remote" fx_empty "" 'G ls-remote "$URL"; G ls-remote --exit-code "$URL"'
    case_ "ls-remote: --get-url" fx_basic "$ADD_ORIGIN" 'G ls-remote --get-url origin; G ls-remote --get-url "$URL"'
    case_ "ls-remote: v0 protocol" fx_basic "" 'G -c protocol.version=0 ls-remote "$URL"; G -c protocol.version=0 ls-remote --heads --symref "$URL"'
    case_ "ls-remote: unknown remote" fx_basic "$ADD_ORIGIN" 'G ls-remote nosuch'
fi

# --- remote ---------------------------------------------------------------------------------

if wanted remote; then
    local_repo='git init -q -b main . && mkdir -p .git/hooks'
    case_ "remote: add and list" fx_basic "$local_repo" 'G remote; G remote add origin "$URL"; G remote; G remote -v; G remote add origin "$URL"; G remote add up https://example.org/x.git; G remote -v'
    case_ "remote: add -t -m --no-tags --tags" fx_basic "$local_repo" 'G remote add -t main -t feature a "$URL"; G remote add --no-tags b "$URL"; G remote add --tags c "$URL"; G remote add -m main -f d "$URL"'
    case_ "remote: add bad name" fx_basic "$local_repo" 'G remote add "a b" "$URL"; G remote add -x y "$URL"'
    case_ "remote: remove" fx_basic "" 'git clone -q "$URL" w; cd w; git remote add other https://example.org/o.git; G remote remove origin; G remote rm other; G remote rm nosuch; G remote -v'
    case_ "remote: rename" fx_basic "" 'git clone -q "$URL" w; cd w; G remote rename origin up; G remote -v; G remote rename nosuch x; G remote add o2 https://example.org/o.git; G remote rename up o2'
    case_ "remote: set-url forms" fx_basic "$ADD_ORIGIN" '
        G remote set-url origin https://example.org/a.git
        G remote set-url --add origin https://example.org/b.git
        G remote set-url --push origin https://example.org/p.git
        G remote set-url origin https://example.org/c.git https://example.org/a.git
        G remote set-url --delete origin https://example.org/b.git
        G remote -v; G remote set-url nosuch x; G remote set-url --delete origin https://example.org/zzz.git'
    case_ "remote: get-url forms" fx_basic "$ADD_ORIGIN" '
        G remote get-url origin; G remote set-url --add origin https://example.org/b.git; G remote get-url --all origin; G remote get-url --push origin; G remote get-url nosuch'
    case_ "remote: show" fx_basic "" 'git clone -q "$URL" w; cd w; G remote show origin; G remote show -n origin; G remote show nosuch'
    case_ "remote: show with a local branch and a stale tracking ref" fx_basic "" '
        git clone -q "$URL" w; cd w; git checkout -q -b topic; git update-ref refs/remotes/origin/gone HEAD; G remote show origin'
    case_ "remote: prune" fx_basic "" 'git clone -q "$URL" w; cd w; git update-ref refs/remotes/origin/gone HEAD; G remote prune -n origin; G remote prune origin; G remote prune origin'
    case_ "remote: set-head" fx_basic "" 'git clone -q "$URL" w; cd w; G remote set-head origin feature; G remote set-head origin -d; G remote set-head origin -a; G remote set-head origin nosuch'
fi

# --- pull ----------------------------------------------------------------------------------

if wanted pull; then
    REMOTE_MOVES='tick; P checkout -q main; printf "r\n" >> "$PUSHER/g.txt"; P add -A; P commit -qm theirs; P push -q origin main'
    LOCAL_COMMIT='tick; printf "m\n" >> mine.txt; git add mine.txt; git commit -qm mine'
    case_ "pull: fast-forward" fx_basic "" 'git clone -q "$URL" w; cd w; '"$REMOTE_MOVES"'; G pull; L log --oneline -3'
    case_ "pull: already up to date" fx_basic "" 'git clone -q "$URL" w; cd w; G pull'
    case_ "pull: diverged without a choice" fx_basic "" 'git clone -q "$URL" w; cd w; '"$LOCAL_COMMIT"'; '"$REMOTE_MOVES"'; G pull'
    case_ "pull: diverged, --no-rebase" fx_basic "" 'git clone -q "$URL" w; cd w; '"$LOCAL_COMMIT"'; '"$REMOTE_MOVES"'; G pull --no-rebase; L log --oneline --graph'
    case_ "pull: diverged, --rebase" fx_basic "" 'git clone -q "$URL" w; cd w; '"$LOCAL_COMMIT"'; '"$REMOTE_MOVES"'; G pull --rebase; L log --oneline --graph'
    case_ "pull: diverged, --ff-only" fx_basic "" 'git clone -q "$URL" w; cd w; '"$LOCAL_COMMIT"'; '"$REMOTE_MOVES"'; G pull --ff-only'
    case_ "pull: pull.rebase configured" fx_basic "" 'git clone -q "$URL" w; cd w; git config pull.rebase true; '"$LOCAL_COMMIT"'; '"$REMOTE_MOVES"'; G pull'
    case_ "pull: a named branch" fx_basic "" 'git clone -q "$URL" w; cd w; G pull origin feature; G pull --no-rebase origin feature'
    case_ "pull: a branch without upstream" fx_basic "" 'git clone -q "$URL" w; cd w; git checkout -q -b local; G pull'
    case_ "pull: nothing on the remote branch" fx_basic "" 'git clone -q "$URL" w; cd w; git config branch.main.merge refs/heads/gone; G pull'
    case_ "pull: --ff-only fast-forwards" fx_basic "" 'git clone -q "$URL" w; cd w; '"$REMOTE_MOVES"'; G pull --ff-only'
    case_ "pull: into a feature branch names it in the merge message" fx_basic "" 'git clone -q "$URL" w; cd w; git checkout -q -b topic origin/main; git branch -q -u origin/main; '"$LOCAL_COMMIT"'; '"$REMOTE_MOVES"'; G pull --no-rebase'
fi

# --- push ----------------------------------------------------------------------------------

if wanted push; then
    NEWWORK='cd w; git config user.name x; mkdir -p .git/hooks; git checkout -q -b topic; tick; printf "t\n" >> t.txt; git add t.txt; git commit -qm topic'
    case_ "push: a new branch" fx_basic "$CLONE_FIRST" 'git clone -q "$URL" w; '"$NEWWORK"'; G push origin topic'
    case_ "push: -u sets the upstream" fx_basic "" 'git clone -q "$URL" w; '"$NEWWORK"'; G push -u origin topic; G push'
    case_ "push: fast-forward and up to date" fx_basic "" 'git clone -q "$URL" w; cd w; tick; printf "m\n" >> f.txt; git commit -qam more; G push; G push; G push origin main'
    case_ "push: no upstream configured" fx_basic "" 'git clone -q "$URL" w; '"$NEWWORK"'; G push; G push origin'
    case_ "push: rejected, behind the remote" fx_basic "" '
        git clone -q "$URL" w; cd w; tick; printf "m\n" >> f.txt; git commit -qam mine
        tick; printf "r\n" >> "$PUSHER/f.txt"; P commit -qam theirs; P push -q origin main
        G fetch -q; G push; G pull -q --no-rebase 2>/dev/null; true'
    case_ "push: rejected, remote has unknown work" fx_basic "" '
        git clone -q "$URL" w; cd w; tick; printf "m\n" >> f.txt; git commit -qam mine
        tick; printf "r\n" >> "$PUSHER/f.txt"; P commit -qam theirs; P push -q origin main
        G push'
    case_ "push: --force replaces after a rewrite" fx_basic "" '
        git clone -q "$URL" w; cd w; tick; git commit -q --amend -m rewritten
        G push; G push --force'
    case_ "push: --force-with-lease, and stale" fx_basic "" '
        git clone -q "$URL" w; cd w; tick; git commit -q --amend -m rewritten
        tick; printf "r\n" >> "$PUSHER/f.txt"; P commit -qam theirs; P push -q origin main
        G push --force-with-lease
        G fetch -q
        G push --force-with-lease'
    case_ "push: +refspec" fx_basic "" 'git clone -q "$URL" w; cd w; tick; git commit -q --amend -m rewritten; G push origin +main'
    case_ "push: --delete and :branch" fx_basic "" 'git clone -q "$URL" w; cd w; G push origin --delete feature; G push origin :nosuch'
    case_ "push: a tag, --tags, an existing tag" fx_basic "" '
        git clone -q "$URL" w; cd w; git tag t1; git tag -a t2 -m two
        G push origin t1; G push --tags; tick; git tag -f t1 HEAD~1 > /dev/null; G push origin t1'
    case_ "push: src:dst and HEAD:ref" fx_basic "" '
        git clone -q "$URL" w; cd w; G push origin HEAD:refs/heads/other; G push origin main:copy; G push origin HEAD:refs/for/main%topic=x,r=a@b'
    case_ "push: push options" fx_basic "" '
        git clone -q "$URL" w; cd w; tick; printf "m\n" >> f.txt; git commit -qam more
        G push -o ci.skip -o "a=b c" origin main'
    case_ "push: remote hook rejects" fx_basic "" '
        git clone -q "$URL" w; cd w; git checkout -q -b denied; tick; printf "d\n" >> d.txt; git add d.txt; git commit -qm d
        G push origin denied'
    case_ "push: --atomic" fx_basic "" '
        git clone -q "$URL" w; cd w; git checkout -q -b a1; tick; printf "a\n" >> a.txt; git add a.txt; git commit -qm a
        G push --atomic origin a1 main'
    case_ "push: to a URL" fx_basic "" 'git clone -q "$URL" w; cd w; git checkout -q -b viaurl; tick; printf "u\n" >> u.txt; git add u.txt; git commit -qm u; G push "$URL" viaurl'
    case_ "push: --all and --dry-run" fx_basic "" '
        git clone -q "$URL" w; cd w; git checkout -q -b b1; tick; printf "b\n" >> b.txt; git add b.txt; git commit -qm b
        G push -n origin --all; G push origin --all'
    case_ "push: missing source" fx_basic "" 'git clone -q "$URL" w; cd w; G push origin nosuch'
    case_ "push: v0 protocol" fx_basic "" 'git clone -q "$URL" w; cd w; tick; printf "m\n" >> f.txt; git commit -qam more; G -c protocol.version=0 push origin main'
fi

# --- proto ------------------------------------------------------------------------------------
# protocol v0 (`-c protocol.version=0`), where the server is asked for nothing newer

if wanted proto; then
    case_ "proto v0: clone" fx_basic "" 'G -c protocol.version=0 clone "$URL" w'
    case_ "proto v0: clone --depth 1 and fetch" fx_basic "" 'G -c protocol.version=0 clone --depth 1 "$URL" w; cd w; G -c protocol.version=0 fetch --depth 2 origin'
    case_ "proto v0: fetch with tags and prune" fx_basic "$ADD_ORIGIN" 'G -c protocol.version=0 fetch origin; P push -q origin --delete feature; G -c protocol.version=0 fetch --prune origin'
    case_ "proto v0: clone --single-branch -b feature" fx_basic "" 'G -c protocol.version=0 clone --single-branch -b feature "$URL" w'
    case_ "proto v1 asked: falls back" fx_basic "" 'G -c protocol.version=1 clone "$URL" w'
fi

# --- auth ------------------------------------------------------------------------------------
# a server that wants HTTP Basic: the throwaway pair below. Both sides get
# the credential the way git documents (URL, askpass, netrc, store helper).

if wanted auth; then
    stop_server
    start_server "zed:s3cret"
    cat > "$WORK/askpass.sh" << 'ASK'
#!/bin/sh
case "$1" in
    Username*) echo zed ;;
    Password*) echo s3cret ;;
esac
ASK
    chmod +x "$WORK/askpass.sh"
    cat > "$WORK/askpass-bad.sh" << 'ASK'
#!/bin/sh
case "$1" in
    Username*) echo zed ;;
    Password*) echo wrong ;;
esac
ASK
    chmod +x "$WORK/askpass-bad.sh"
    AUTHED='${URL/http:\/\//http:\/\/zed:s3cret@}'
    case_ "auth: credentials in the URL" fx_basic "" 'G ls-remote "http://zed:s3cret@${URL#http://}"; G clone "http://zed:s3cret@${URL#http://}" w; cd w; L config remote.origin.url'
    case_ "auth: no credentials and no way to ask" fx_basic "" 'G ls-remote "$URL"; G clone "$URL" w'
    case_ "auth: wrong credentials" fx_basic "" 'G ls-remote "http://zed:nope@${URL#http://}"'
    case_ "auth: askpass" fx_basic "" 'export GIT_ASKPASS="'"$WORK"'/askpass.sh"; G ls-remote "$URL"; G clone "$URL" w'
    case_ "auth: askpass with a wrong password" fx_basic "" 'export GIT_ASKPASS="'"$WORK"'/askpass-bad.sh"; G ls-remote "$URL"'
    case_ "auth: netrc" fx_basic "" 'mkdir -p "$PWD/home"; printf "machine 127.0.0.1 login zed password s3cret\n" > "$PWD/home/.netrc"; export HOME="$PWD/home"; G ls-remote "$URL"'
    case_ "auth: store helper approves and reuses" fx_basic "" 'mkdir -p "$PWD/home"; export HOME="$PWD/home"; export GIT_ASKPASS="'"$WORK"'/askpass.sh"; G -c credential.helper=store ls-remote "$URL"; unset GIT_ASKPASS; G -c credential.helper=store ls-remote "$URL"; cat "$PWD/home/.git-credentials" | sed "s/s3cret/SECRET/; s/:[0-9]*$//"'
    case_ "auth: push with credentials" fx_basic "" 'export GIT_ASKPASS="'"$WORK"'/askpass.sh"; git clone -q "http://zed:s3cret@${URL#http://}" w; cd w; tick; printf "m\n" >> f.txt; git commit -qam more; G push origin main'
    stop_server
    start_server
fi

echo
if [ "$bad" -eq 0 ]; then
    echo "compare_net: $n cases, all agree with git"
else
    echo "compare_net: $bad of $n cases differ"
fi
exit "$bad"
