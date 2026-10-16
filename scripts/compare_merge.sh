#!/usr/bin/env bash
# The history-changing commands of `1git` (`stash`, `cherry-pick`, `revert`,
# `merge`, `rebase`, `clean`, `worktree`) beside the real `git`, on pairs of
# identical disposable repositories. Same method as compare_write.sh.
#
#   bash scripts/compare_merge.sh <1git-binary> [workdir] [group...]
#
# groups: stash pick revert merge rebase clean worktree  (default: all)
#
# A case is a fixture (built twice from the same script with fixed identities
# and dates, so every object id is the same in both), some setup lines run
# with real git on both, and the commands under test, written as `G <args>`:
# `G` is real `git` in the first repository and `1git` in the second. After
# the commands both repositories are dumped and compared:
#
#   - stdout and exit status of every `G` call;
#   - `ls-files -s`, `for-each-ref`, HEAD, `status --porcelain=v2 -b`, the
#     reflogs (bytes: identity and dates are fixed), the work tree (names,
#     modes, content hashes), and the state files (MERGE_HEAD, ...);
#   - `git fsck --strict` clean on ours.
#
# Because dates and identities are fixed, a commit or tree id that differs is
# a real difference: the object ids must be IDENTICAL. stderr is not compared
# (hints are shorter on purpose); its presence is shown on a failure.
set -uo pipefail

# shellcheck source=lib_cli.sh
. "$(cd "$(dirname "$0")" && pwd)/lib_cli.sh"

OURS=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${2:-$(mktemp -d)}
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
shift
shift || true
GROUPS_WANTED=${*:-stash pick revert merge rebase clean worktree}

# --- the icase cases on a real case-insensitive volume -----------------------------------
# As in compare_write.sh: where Linux can mount a tmpfs with `casefold` in a
# user namespace the `icase:` cases are run a second time on it (a real
# folding volume: lstat of the other spelling succeeds, readdir has one
# name), besides the run below on the hard-link stand-in (compare_merge_icase.sh).
if [ -z "${ICASE_NS:-}" ] && command -v unshare > /dev/null 2>&1 && command -v chattr > /dev/null 2>&1; then
    cf=$WORK/casefold
    mkdir -p "$cf"
    if unshare -Urm sh -c 'mount -t tmpfs -o casefold tmpfs "$1" && chattr +F "$1" && : > "$1/Zz" && [ -e "$1/zZ" ]' _ "$cf" 2> /dev/null; then
        echo "compare_merge: icase cases on a casefold tmpfs (real insensitive volume)"
        ICASE_NS=1 ONLY="icase:" unshare -Urm bash -c 'mount -t tmpfs -o casefold tmpfs "$1" && chattr +F "$1" && exec bash "$2" "$3" "$1" $4' _ "$cf" "$HERE/compare_merge.sh" "$OURS" "$GROUPS_WANTED"
        [ $? -eq 0 ] || ns_bad=1
    fi
fi

# shellcheck source=fixtures_look.sh
. "$HERE/fixtures_look.sh"
export GIT_AUTHOR_DATE="1800000000 +0000" GIT_COMMITTER_DATE="1800000000 +0000"
umask 022

bad=${ns_bad:-0}
n=0

# --- fixtures -------------------------------------------------------------------------

fx_base() {
    new_repo "$1"
    printf 'alpha\nbeta\ngamma\n' > a.txt
    printf 'one\n' > b.txt
    mkdir -p dir/sub
    printf 'cee\n' > dir/c.txt
    printf 'dee\n' > dir/sub/d.txt
    printf 'with space\n' > 'sp ace.txt'
    printf 'uni\n' > 'ünï.txt'
    printf '#!/bin/sh\necho hi\n' > exec.sh
    chmod +x exec.sh
    g add -A
    commit_at "first"
    printf 'alpha\nbeta\ngamma\ndelta\n' > a.txt
    printf 'one\ntwo\n' > b.txt
    g add -A
    commit_at "second"
    g branch side HEAD~1
}

fx_empty() {
    new_repo "$1"
    printf 'x\n' > x.txt
}

fx_linear() {
    new_repo "$1"
    printf 'l1\n' > f.txt
    g add f.txt
    commit_at "c1"
    printf 'l1\nl2\n' > f.txt
    g commit -qam "c2"
    printf 'l1\nl2\nl3\n' > f.txt
    tick
    g commit -qam "c3"
    g branch topic
    g tag v1 HEAD~1
}

# a merge with a conflict left in the index
fx_conflict() {
    new_repo "$1"
    printf 'base\nline\n' > f.txt
    printf 'keep\n' > k.txt
    g add -A
    commit_at "base"
    g checkout -q -b other
    printf 'base\nother\n' > f.txt
    g commit -qam "other side"
    g checkout -q main
    printf 'base\nmain\n' > f.txt
    g commit -qam "main side"
    g merge other > /dev/null 2>&1
    true
}

fx_merge() {
    new_repo "$1"
    printf 'a\n' > a.txt
    g add -A
    commit_at "root"
    g checkout -q -b feat
    printf 'f\n' > f.txt
    g add -A
    commit_at "feat work"
    g checkout -q main
    printf 'm\n' > m.txt
    g add -A
    commit_at "main work"
    tick
    g merge --no-ff -m "merge feat" feat > /dev/null
}

fx_crlf() {
    new_repo "$1"
    printf 'one\r\ntwo\r\n' > win.txt
    printf 'mixed\r\nline\n' > mix.txt
    g add -A
    commit_at "crlf"
}

fx_unicode() {
    new_repo "$1"
    mkdir -p 'dír ectory'
    printf 'x\n' > 'dír ectory/fïle one.txt'
    printf 'y\n' > 'tab	name.txt' 2>/dev/null || printf 'y\n' > 'tab_name.txt'
    printf 'z\n' > '日本語.txt'
    g add -A
    commit_at "unicode"
}

fx_ignore() {
    new_repo "$1"
    printf '*.log\nbuild/\n' > .gitignore
    printf 'k\n' > keep.txt
    g add -A
    commit_at "ignore"
    printf 'l\n' > debug.log
    mkdir -p build
    printf 'o\n' > build/out.o
    printf 'n\n' > new.txt
}

# symlinks: one tracked, and a branch that points it elsewhere
fx_links() {
    new_repo "$1"
    printf 'target\n' > real.txt
    ln -s real.txt link
    ln -s missing dangling
    mkdir sub
    ln -s ../real.txt sub/up
    g add -A
    commit_at "links"
    g switch -q -c other
    rm link
    ln -s sub/up link
    g add -A
    commit_at "retarget"
    g switch -q main
}

# a cherry-pick stopped on a conflict
fx_pick() {
    new_repo "$1"
    printf 'base\nline\n' > f.txt
    g add -A
    commit_at "base"
    g checkout -q -b other
    printf 'base\nother\n' > f.txt
    printf 'new\n' > o.txt
    g add -A
    GIT_AUTHOR_NAME="Pick Author" GIT_AUTHOR_EMAIL="pick@example.com" GIT_AUTHOR_DATE="1600000000 +0300" g commit -qm "other side"
    g checkout -q main
    printf 'base\nmain\n' > f.txt
    g commit -qam "main side"
    g cherry-pick other > /dev/null 2>&1
    true
}

# --- harness ---
# --- the harness ----------------------------------------------------------------------

dump_state() {
    local repo=$1
    (
        cd "$repo" || exit 1
        echo "## ls-files -s"
        git ls-files -s
        echo "## refs"
        git for-each-ref
        echo "## HEAD"
        git symbolic-ref -q HEAD || true
        git rev-parse -q --verify HEAD || true
        echo "## config"
        git config --local --list | grep -vi '^gerrit\.' | LC_ALL=C sort
        echo "## status"
        git status --porcelain=v2 -b 2>&1
        echo "## logs"
        if [ -d .git/logs ]; then
            (cd .git/logs && find . -type f | LC_ALL=C sort | while read -r f; do echo "-- $f"; cat "$f"; done)
        fi
        echo "## state"
        for f in MERGE_HEAD MERGE_MSG MERGE_MODE ORIG_HEAD CHERRY_PICK_HEAD REVERT_HEAD SQUASH_MSG AUTO_MERGE; do
            if [ -e ".git/$f" ]; then echo "$f: $(cat ".git/$f" | head -c 400 | tr '\n' '|')"; fi
        done
        for d in sequencer rebase-merge rebase-apply worktrees; do
            if [ -d ".git/$d" ]; then
                (cd ".git/$d" && find . -type f ! -name index | LC_ALL=C sort | while read -r f; do echo "$d/$f: $(head -c 600 "$f" | tr '\n' '|')"; done)
            fi
        done
        echo "## unmerged"
        git ls-files -u
        echo "## tree"
        find . -path ./.git -prune -o \( -type f -o -type l \) -print | LC_ALL=C sort | while read -r f; do
            if [ -L "$f" ]; then echo "L $f"; elif [ "$(basename "$f")" = .git ]; then printf 'gitfile %s %s\n' "$f" "$(sed "s|$repo|REPO|g" "$f")"; else printf '%s %s %s\n' "$(stat -c %a "$f")" "$f" "$(sha1sum < "$f" | cut -c1-12)"; fi
        done
        echo "## dirs"
        find . -path ./.git -prune -o -type d -print | LC_ALL=C sort
    )
}

run_side() {
    local bin=$1 repo=$2 fixture=$3 setup=$4 script=$5 log=$6
    : > "$log"
    : > "$log.err"
    (
        cd "$WORK" || exit 1
        "$fixture" "$repo" > /dev/null 2>&1
        cd "$repo" || exit 1
        export GIT_AUTHOR_DATE="1800000000 +0000" GIT_COMMITTER_DATE="1800000000 +0000"
        # which program the case runs: some cases differ per side (the Gerrit
        # hook is installed for git, `gerrit.createChangeId` set for 1git)
        if [ "$bin" = git ]; then SIDE=git; else SIDE=ours; fi
        export SIDE
        mkdir -p .git/hooks
        eval "$setup" > /dev/null 2>&1
        T=$(mktemp -d)
        G() {
            side_run "$bin" "$@" > "$T/o" 2> "$T/e"
            local rc=$?
            rc=$(norm_rc $rc)
            { local shown="$*"; printf '$ %s\n' "${shown//--change-id /}"; cat "$T/o"; printf 'rc=%s\n' "$rc"; } >> "$log"
            { printf '$ %s\n' "$*"; cat "$T/e"; } >> "$log.err"
            return $rc
        }
        eval "$script"
        rm -rf "$T"
    ) > /dev/null 2>&1
}

# case_ <label> <fixture> <setup> <script>
case_() {
    local label=$1 fixture=$2 setup=$3 script=$4
    # ONLY=<text> runs the cases whose label contains it; SHOW=1 prints both
    # logs and state dumps of each
    if [ -n "${ONLY:-}" ] && [[ "$label" != *"$ONLY"* ]]; then
        return 0
    fi
    n=$((n + 1))
    local a=$WORK/case-a b=$WORK/case-b
    rm -rf "$a" "$b"
    run_side git "$a" "$fixture" "$setup" "$script" "$WORK/log-a"
    run_side "$OURS" "$b" "$fixture" "$setup" "$script" "$WORK/log-b"
    dump_state "$a" > "$WORK/dump-a" 2>&1
    dump_state "$b" > "$WORK/dump-b" 2>&1
    # absolute paths (worktree commands print and store them) differ by side
    sed -i.bak "s|$a|REPO|g" "$WORK/log-a" "$WORK/dump-a"; rm -f "$WORK/log-a.bak" "$WORK/dump-a.bak"
    sed -i.bak "s|$b|REPO|g" "$WORK/log-b" "$WORK/dump-b"; rm -f "$WORK/log-b.bak" "$WORK/dump-b.bak"
    local failed=0
    if [ -n "${SHOW:-}" ]; then
        echo "=== $label"; echo "--- git"; cat "$WORK/log-a"; echo "--- ours"; cat "$WORK/log-b"; echo "--- stderr"; cat "$WORK/log-b.err"
    fi
    if ! cmp -s "$WORK/log-a" "$WORK/log-b"; then
        failed=1
        printf '\033[31mdiffer\033[0m %s: output\n' "$label"
        diff "$WORK/log-a" "$WORK/log-b" | head -14 | sed 's/^/       /'
        head -6 "$WORK/log-b.err" | sed 's/^/       stderr: /'
    fi
    if ! cmp -s "$WORK/dump-a" "$WORK/dump-b"; then
        failed=1
        printf '\033[31mdiffer\033[0m %s: state\n' "$label"
        diff "$WORK/dump-a" "$WORK/dump-b" | head -14 | sed 's/^/       /'
    fi
    local fsck
    fsck=$(cd "$b" && git fsck --strict --no-dangling 2>&1)
    if [ -n "$fsck" ] && echo "$fsck" | grep -qiE 'error|missing|broken|invalid|corrupt'; then
        failed=1
        printf '\033[31mfsck\033[0m %s: %s\n' "$label" "$(echo "$fsck" | head -3)"
    fi
    [ $failed -eq 0 ] || bad=$((bad + 1))
}

wanted() {
    case " $GROUPS_WANTED " in *" $1 "*) return 0 ;; esac
    return 1
}


# --- more fixtures --------------------------------------------------------------------

# a repository with an index change, a work tree change and untracked files
fx_dirty() {
    fx_base "$1"
    echo staged >> b.txt
    git add b.txt
    echo local >> a.txt
    echo untracked > un.txt
    mkdir -p dir/nu
    echo n > dir/nu/n.txt
}

# two branches that change different files, and one that conflicts with main
fx_branches() {
    new_repo "$1"
    printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n' > f.txt
    printf 'g1\n' > g.txt
    printf 'h1\n' > h.txt
    g add -A
    commit_at "base"
    g checkout -q -b feat
    printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nF8\n' > f.txt
    g commit -qam "feat: f"
    printf 'g1\ng2\n' > g.txt
    g commit -qam "feat: g"
    printf 'new\n' > n.txt
    g add n.txt
    commit_at "feat: n"
    g checkout -q -b clash main
    printf 'CLASH\n' > h.txt
    g commit -qam "clash: h"
    g checkout -q main
    printf 'H1\nh1\n' > h.txt
    g commit -qam "main: h"
    printf 'l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n' > f.txt
    g commit -qam "main: f top"
}

# main with a merge commit on it (feat merged with --no-ff), a later commit,
# and an unmerged branch `other` that touches a file feat also touched
fx_mergecommit() {
    new_repo "$1"
    printf 'a1\na2\na3\n' > a.txt
    printf 'b1\n' > b.txt
    g add -A
    commit_at "base"
    g checkout -q -b feat
    printf 'a1\na2\na3\na4\n' > a.txt
    g commit -qam "feat: a4"
    printf 'f\n' > f.txt
    g add f.txt
    commit_at "feat: f"
    g checkout -q main
    printf 'b0\nb1\n' > b.txt
    g commit -qam "main: b0"
    tick
    g merge -q --no-ff -m "Merge branch feat" feat > /dev/null
    printf 'b0\nb1\nb2\n' > b.txt
    g commit -qam "main: b2"
    g checkout -q -b other HEAD~3
    printf 'a1\na2\nOTHER\n' > a.txt
    printf 'o\n' > o.txt
    g add o.txt
    g commit -qam "other: a3 and o"
    printf 'x\n' > x.txt
    g add x.txt
    commit_at "other: x"
    g checkout -q main
}

# a base with a few sizeable files, to rename and edit on two branches
fx_rbase() {
    new_repo "$1"
    mkdir -p src docs
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'line %s of alpha\n' "$i"; done > a.txt
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'line %s of beta\n' "$i"; done > b.txt
    for i in 1 2 3 4 5 6 7 8; do printf 'src %s\n' "$i"; done > src/s.txt
    for i in 1 2 3 4 5 6 7 8; do printf 'doc %s\n' "$i"; done > docs/d.txt
    printf 'keep\n' > k.txt
    g add -A
    commit_at "base"
    g branch other
}

# a criss-cross history: a and b merged into each other, then both move on
fx_crisscross() {
    new_repo "$1"
    printf 'one\ntwo\nthree\nfour\nfive\n' > f.txt
    printf 'g\n' > g.txt
    g add -A
    commit_at "root"
    g checkout -q -b a
    printf 'one\nA2\nthree\nfour\nfive\n' > f.txt
    g commit -qam "a: two"
    g checkout -q -b b main
    printf 'one\ntwo\nthree\nfour\nB5\n' > f.txt
    g commit -qam "b: five"
    g checkout -q a
    tick
    g merge -q --no-edit b > /dev/null
    git branch a1
    g checkout -q b
    tick
    g merge -q --no-edit a1~1 > /dev/null 2>&1
    printf 'g\nG2\n' > g.txt
    g commit -qam "b: g"
    g checkout -q a
    printf 'one\nA2\nthree\nA4\nB5\n' > f.txt
    g commit -qam "a: four"
    g branch -q -D a1
}

# A case-only rename (a.txt -> A.txt) needs 1git to honor core.ignorecase when
# the volume folds case (macOS), as git itself does. $CASE_ONLY is the new
# name for such a rename, or moved.txt when this 1git does not honor it on this
# volume (the cases then still run, as plain renames).
probe_case_only() {
    local d=$WORK/icase-probe
    rm -rf "$d"; mkdir -p "$d/.git"; : > "$d/.git/config"
    if [ ! -e "$d/.git/CoNfIg" ]; then
        rm -rf "$d"
        echo A.txt
        return
    fi
    rm -rf "$d"; mkdir -p "$d"
    if (cd "$d" && one_run "$OURS" init -q . > /dev/null 2>&1 && [ "$(git config --local core.ignorecase)" = true ]); then
        echo A.txt
    else
        echo moved.txt
    fi
    rm -rf "$d"
}
CASE_ONLY=$(probe_case_only)

for more in "$HERE"/compare_merge_*.sh; do
    . "$more"
done

echo "compare_merge: $n cases, $bad differing"
[ $bad -eq 0 ]
