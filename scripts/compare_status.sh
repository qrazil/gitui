#!/usr/bin/env bash
# `1git status` beside the real `git status`, on disposable fixture repos,
# compared octet for octet (stdout) and by exit status.
#
#   bash scripts/compare_status.sh <1git-binary> [workdir]
#
# Every fixture is built from scratch under <workdir> with fixed identities
# and dates, then each of these forms is run by both programs:
#
#   long, -s, -sb, --porcelain, --porcelain=v2 -b, -z, -uall, -uno,
#   --ignored, -c color.status=always (long and -s), a subdirectory, a
#   pathspec.
#
# Nothing here writes outside <workdir>. `git` is the oracle; there is no
# expected-output file to drift.
set -uo pipefail

OURS=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
WORK=${2:-$(mktemp -d)}
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)

export LC_ALL=C TZ=UTC
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.com
export GIT_AUTHOR_DATE="2024-01-02T03:04:05+0000" GIT_COMMITTER_DATE="2024-01-02T03:04:05+0000"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE NO_COLOR

bad=0
n=0
g() { git -c init.defaultBranch=main -c advice.detachedHead=false "$@"; }

# fixture <name>: a repository with one commit of four files
fixture() {
    local dir=$WORK/$1
    rm -rf "$dir"
    mkdir -p "$dir"
    ( cd "$dir" && g init -q . \
        && printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n' > a.txt \
        && printf 'bee\n' > b.txt \
        && mkdir dir && printf 'cee\nsee\n' > dir/c.txt \
        && printf '#!/bin/sh\necho hi\n' > script.sh && chmod +x script.sh \
        && g add -A && g commit -q -m base )
    echo "$dir"
}

# compare <label> <repo> <args...>
compare() {
    local label=$1 repo=$2
    shift 2
    n=$((n + 1))
    g -C "$repo" status "$@" > "$WORK/want" 2> "$WORK/want.err"; local want_rc=$?
    "$OURS" -C "$repo" status "$@" > "$WORK/got" 2> "$WORK/got.err"; local got_rc=$?
    if ! cmp -s "$WORK/want" "$WORK/got" || [ $want_rc -ne $got_rc ]; then
        printf '\033[31mdiffer\033[0m %s: status %s\n' "$label" "$*"
        printf '       exit: git %s, 1git %s\n' "$want_rc" "$got_rc"
        diff <(sed 's/$/$/' "$WORK/want" | cat -v) <(sed 's/$/$/' "$WORK/got" | cat -v) | head -12 | sed 's/^/       /'
        head -3 "$WORK/got.err" | sed 's/^/       stderr: /'
        bad=$((bad + 1))
    fi
}

# every form, on one repository
forms() {
    local label=$1 repo=$2
    compare "$label" "$repo"
    compare "$label" "$repo" -s
    compare "$label" "$repo" -sb
    compare "$label" "$repo" --porcelain
    compare "$label" "$repo" --porcelain=v2 -b
    compare "$label" "$repo" --porcelain=v2
    compare "$label" "$repo" -z
    compare "$label" "$repo" -sbz
    compare "$label" "$repo" -uall
    compare "$label" "$repo" -s -uall
    compare "$label" "$repo" -uno
    compare "$label" "$repo" -s -uno
    compare "$label" "$repo" --ignored
    compare "$label" "$repo" -s --ignored
    compare "$label" "$repo" -c color.status=always
    compare "$label" "$repo" -c color.status=always -sb
    compare "$label" "$repo" -c color.ui=always -s
    compare "$label" "$repo" -c color.status=false -s
    compare "$label" "$repo" -- a.txt dir
    compare "$label" "$repo" -s -- dir
    compare "$label" "$repo" --no-renames -s
    compare "$label" "$repo" --show-stash
}

# --- the fixtures ------------------------------------------------------------

r=$(fixture clean)
forms clean "$r"

r=$(fixture untracked)
( cd "$r" && echo x > new.txt && mkdir -p newdir/inner && echo y > newdir/inner/f && echo z > newdir/g \
    && echo w > dir/extra.txt && mkdir empty && echo 'with space' > 'sp ace.txt' )
forms untracked "$r"

r=$(fixture modified)
( cd "$r" && echo more >> a.txt && echo changed > dir/c.txt )
forms modified "$r"

r=$(fixture staged)
( cd "$r" && echo n > added.txt && echo more >> b.txt && g add added.txt b.txt )
forms staged "$r"

r=$(fixture staged-modified)
( cd "$r" && echo more >> a.txt && g add a.txt && echo again >> a.txt && echo q > fresh && g add fresh && echo r >> fresh )
forms staged+modified "$r"

r=$(fixture deleted)
( cd "$r" && rm b.txt && g rm -q dir/c.txt )
forms deleted "$r"

r=$(fixture renamed)
( cd "$r" && g mv b.txt bee.txt && g mv a.txt dir/a2.txt && echo 'nine' >> dir/a2.txt && g add dir/a2.txt )
forms renamed "$r"

r=$(fixture renamed-edited)
( cd "$r" && g mv dir/c.txt dir/cee.txt && echo more >> dir/cee.txt )
forms renamed+modified "$r"

r=$(fixture mode)
( cd "$r" && chmod +x b.txt && chmod -x script.sh && g add script.sh && chmod +x dir/c.txt )
forms mode "$r"

r=$(fixture typechange)
( cd "$r" && rm b.txt && ln -s a.txt b.txt && g add b.txt && rm dir/c.txt && ln -s ../a.txt dir/c.txt )
forms typechange "$r"

r=$(fixture ignored)
( cd "$r" && printf '*.log\nbuild/\n' > .gitignore && g add .gitignore && g commit -q -m ign \
    && echo l > x.log && mkdir -p build/out && echo o > build/out/f && echo u > untracked.txt && echo e > dir/e.log )
forms ignored "$r"

r=$(fixture conflict)
( cd "$r" && g checkout -q -b topic && echo topic > a.txt && g commit -qam topic \
    && g checkout -q main && echo main > a.txt && g commit -qam main && g merge topic >/dev/null 2>&1; true )
forms conflict-merge "$r"
( cd "$r" && echo resolved > a.txt && g add a.txt )
forms merge-resolved "$r"

r=$(fixture conflict-del)
( cd "$r" && g checkout -q -b topic && g rm -q b.txt && g commit -qm rm \
    && g checkout -q main && echo changed > b.txt && g commit -qam edit && echo n1 > n.txt && g add n.txt && g commit -qm n \
    && g merge topic >/dev/null 2>&1; true )
forms conflict-deleted "$r"

r=$(fixture conflict-add)
( cd "$r" && g checkout -q -b topic && echo t > new && g add new && g commit -qm t \
    && g checkout -q main && echo m > new && g add new && g commit -qm m && g merge topic >/dev/null 2>&1; true )
forms conflict-both-added "$r"

r=$(fixture cherry)
( cd "$r" && g checkout -q -b topic && echo topic > a.txt && g commit -qam topic \
    && g checkout -q main && echo main > a.txt && g commit -qam main && g cherry-pick topic >/dev/null 2>&1; true )
forms cherry-pick "$r"

r=$(fixture detached)
( cd "$r" && echo two > b.txt && g commit -qam two && g checkout -q --detach HEAD~1 )
forms detached "$r"
( cd "$r" && echo dirty >> a.txt )
forms detached-dirty "$r"

r=$(fixture detached-tag)
( cd "$r" && echo two > b.txt && g commit -qam two && g tag v1 HEAD~1 && g checkout -q v1 )
forms detached-tag "$r"

r=$(fixture detached-moved)
( cd "$r" && g checkout -q --detach && echo two > b.txt && g commit -qam two )
forms detached-moved "$r"

r=$(fixture ahead)
( cd "$r" && g checkout -q -b feature && g branch -q -u main && echo f > f.txt && g add f.txt && g commit -qm f )
forms ahead "$r"

r=$(fixture behind)
( cd "$r" && g checkout -q -b feature && g branch -q -u main && g checkout -q main && echo m > m.txt && g add m.txt && g commit -qm m && g checkout -q feature )
forms behind "$r"

r=$(fixture diverged)
( cd "$r" && g checkout -q -b feature && g branch -q -u main && echo f > f.txt && g add f.txt && g commit -qm f \
    && g checkout -q main && echo m > m.txt && g add m.txt && g commit -qm m && echo m2 >> m.txt && g commit -qam m2 && g checkout -q feature )
forms diverged "$r"

r=$(fixture gone)
( cd "$r" && g checkout -q -b feature && g branch -q -u main && g config branch.feature.merge refs/heads/vanished )
forms gone "$r"

r=$WORK/empty
rm -rf "$r"; mkdir -p "$r"; ( cd "$r" && g init -q . )
forms empty "$r"
( cd "$r" && echo x > f && mkdir d && echo y > d/g )
forms empty-untracked "$r"
( cd "$r" && g add f )
forms empty-staged "$r"

r=$(fixture revert)
( cd "$r" && echo two > a.txt && g commit -qam two && echo three > a.txt && g commit -qam three && g revert HEAD~1 >/dev/null 2>&1; true )
forms revert "$r"

r=$(fixture rebase)
( cd "$r" && g checkout -q -b topic && echo topic > a.txt && g commit -qam topic \
    && g checkout -q main && echo main > a.txt && g commit -qam main && g checkout -q topic && g rebase main >/dev/null 2>&1; true )
forms rebase "$r"
( cd "$r" && echo fixed > a.txt && g add a.txt )
forms rebase-resolved "$r"

r=$(fixture rebase3)
( cd "$r" && g checkout -q -b topic && echo t1 > t1 && g add t1 && g commit -qm t1 && echo topic > a.txt && g commit -qam t2 \
    && echo t3 > t3 && g add t3 && g commit -qm t3 && echo t4 > t4 && g add t4 && g commit -qm t4 \
    && g checkout -q main && echo main > a.txt && g commit -qam main && g checkout -q topic && g rebase main >/dev/null 2>&1; true )
forms rebase-todo "$r"

r=$(fixture special)
( cd "$r" && echo 1 > 'tab	name' && echo 2 > 'quo"te' && echo 3 > 'café.txt' && echo 4 > 'sp ace.txt' && g add 'sp ace.txt' 'café.txt' )
forms special-names "$r"

r=$(fixture nested)
( cd "$r" && mkdir inner && ( cd inner && g init -q . && echo i > f && g add f && g commit -qm inner ) && echo u > top )
forms nested-repo "$r"

r=$(fixture stash)
( cd "$r" && echo wip >> a.txt && g stash -q && echo wip2 >> a.txt && g stash -q && echo dirty >> b.txt )
forms stash "$r"
( cd "$r" && g checkout -q -- . )
forms stash-clean "$r"
( cd "$r" && g config status.showStash true && echo e >> a.txt && g add a.txt )
forms stash-config-staged "$r"

r=$(fixture intent)
( cd "$r" && mkdir -p deep/er/est && echo x > deep/er/est/f && echo y > deep/er/g && g add deep/er/est/f && echo z >> deep/er/est/f )
forms deep "$r"

r=$(fixture subdir)
( cd "$r" && echo more >> dir/c.txt && echo n > dir/new.txt && echo m >> a.txt && mkdir dir/deep && echo d > dir/deep/x )
forms subdir-root "$r"
for args in "" "-s" "-sb" "--porcelain" "-s ."; do
    n=$((n + 1))
    # shellcheck disable=SC2086
    ( cd "$r/dir" && g status $args ) > "$WORK/want" 2>&1; want_rc=$?
    # shellcheck disable=SC2086
    ( cd "$r/dir" && "$OURS" status $args ) > "$WORK/got" 2>&1; got_rc=$?
    if ! cmp -s "$WORK/want" "$WORK/got" || [ $want_rc -ne $got_rc ]; then
        printf '\033[31mdiffer\033[0m subdir (cwd dir): status %s\n' "$args"
        diff <(sed 's/$/$/' "$WORK/want" | cat -v) <(sed 's/$/$/' "$WORK/got" | cat -v) | head -12 | sed 's/^/       /'
        bad=$((bad + 1))
    fi
done

r=$(fixture config-short)
( cd "$r" && echo more >> a.txt && echo u > u && g config status.short true && g config status.branch true )
compare config-short "$r"
compare config-short "$r" --long

# not a repository: only the exit status
n=$((n + 1))
mkdir -p "$WORK/nowhere"
( cd "$WORK/nowhere" && GIT_CEILING_DIRECTORIES=$WORK "$OURS" status ) >/dev/null 2>&1; got_rc=$?
if [ $got_rc -ne 128 ]; then
    printf '\033[31mdiffer\033[0m outside a repository: exit %s, git says 128\n' "$got_rc"
    bad=$((bad + 1))
fi

if [ $bad -eq 0 ]; then
    echo "     $n status comparisons against git, all identical"
fi
exit $bad
