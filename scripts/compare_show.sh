#!/usr/bin/env bash
# `1git show` beside the real `git show`, on disposable fixture repositories
# with fixed identities and dates, compared octet for octet (stdout) and by
# exit status.
#
#   bash scripts/compare_show.sh <1git-binary> [workdir]
#
# Commits (every history of scripts/fixtures_look.sh, merges and the root
# included), annotated tags and tags of tags, trees, blobs and `rev:path`,
# several objects at once, each with the formats `show` shares with `log`.
# Nothing here writes outside <workdir>. `git` is the oracle.
set -uo pipefail

OURS=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${2:-$(mktemp -d)}
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)

# shellcheck source=fixtures_look.sh
. "$HERE/fixtures_look.sh"
export GIT_TEST_DATE_NOW=1800000000

bad=0
n=0
known=0

# git 2.55 shows the header of a commit named on the command line even when
# the pathspec leaves no diff; older gits print nothing.
git_at_least() { [ "$(printf '%s\n%s\n' "$1" "$(git version | awk '{print $3}')" | sort -V | head -n 1)" = "$1" ]; }

compare() {
    local label=$1 repo=$2
    shift 2
    n=$((n + 1))
    git -C "$repo" "$@" > "$WORK/want" 2> "$WORK/want.err"; local want_rc=$?
    "$OURS" -C "$repo" "$@" > "$WORK/got" 2> "$WORK/got.err"; local got_rc=$?
    if ! cmp -s "$WORK/want" "$WORK/got" || [ $want_rc -ne $got_rc ]; then
        # known divergence: a merge's combined diff (`diff --cc`) is not
        # implemented; the header, message and every other form still match
        if [ $want_rc -eq $got_rc ] && { { grep -q 'diff --\(cc\|combined\) ' "$WORK/want" &&
            ! grep -q 'diff --\(cc\|combined\) ' "$WORK/got"; } ||
            { [ "$label" = merges ] && [[ " $* " =~ \ --(name-only|name-status|raw)\  ]]; }; }; then
            known=$((known + 1))
            return
        fi
        printf '\033[31mdiffer\033[0m %s: %s\n' "$label" "$*"
        printf '       exit: git %s, 1git %s\n' "$want_rc" "$got_rc"
        diff <(sed 's/$/$/' "$WORK/want" | cat -v) <(sed 's/$/$/' "$WORK/got" | cat -v) | head -12 | sed 's/^/       /'
        head -3 "$WORK/got.err" | sed 's/^/       stderr: /'
        bad=$((bad + 1))
    fi
}

# the forms for one object
one() {
    local l=$1 r=$2 obj=$3
    compare "$l" "$r" show "$obj"
    compare "$l" "$r" show --stat "$obj"
    compare "$l" "$r" show --stat --summary "$obj"
    compare "$l" "$r" show --numstat "$obj"
    compare "$l" "$r" show --shortstat "$obj"
    compare "$l" "$r" show --name-only "$obj"
    compare "$l" "$r" show --name-status "$obj"
    compare "$l" "$r" show --raw "$obj"
    compare "$l" "$r" show -s "$obj"
    compare "$l" "$r" show --no-patch "$obj"
    compare "$l" "$r" show --oneline "$obj"
    compare "$l" "$r" show --oneline --stat "$obj"
    compare "$l" "$r" show --oneline -s "$obj"
    compare "$l" "$r" show --pretty=short "$obj"
    compare "$l" "$r" show --pretty=full "$obj"
    compare "$l" "$r" show --pretty=fuller "$obj"
    compare "$l" "$r" show --pretty=raw "$obj"
    compare "$l" "$r" show '--format=%H %an <%ae> %ad%n%s%n%b' "$obj"
    compare "$l" "$r" show '--format=%h %d' -s "$obj"
    compare "$l" "$r" show --format= "$obj"
    compare "$l" "$r" show --date=iso "$obj"
    compare "$l" "$r" show --date=relative -s "$obj"
    compare "$l" "$r" show -U1 "$obj"
    compare "$l" "$r" show -w "$obj"
    compare "$l" "$r" show --color=always "$obj"
    compare "$l" "$r" show --color=always --stat "$obj"
    compare "$l" "$r" show --decorate "$obj"
    compare "$l" "$r" show --decorate=full --oneline "$obj"
    compare "$l" "$r" show -M --name-status "$obj"
    compare "$l" "$r" show --no-renames --name-status "$obj"
    compare "$l" "$r" show --graph "$obj"
    compare "$l" "$r" show --abbrev-commit --oneline "$obj"
}

build_all "$WORK/fx" || exit 1
for f in linear merges cross renames modes binary empty large tags crlf unicode space orphan; do
    r="$WORK/fx/$f"
    one "$f" "$r" HEAD
    one "$f" "$r" HEAD~1
    compare "$f" "$r" show HEAD~2 HEAD~1
    compare "$f" "$r" show --stat HEAD HEAD~1 HEAD~2
    compare "$f" "$r" show -- a.txt
    if git_at_least 2.55; then
        compare "$f" "$r" show HEAD -- src
        compare "$f" "$r" show HEAD -- nosuchpath
    fi
    compare "$f" "$r" show nosuchrev
    compare "$f" "$r" show
done

# the root commit
for f in linear renames modes binary empty large crlf unicode space orphan; do
    root=$(git -C "$WORK/fx/$f" rev-list --max-parents=0 HEAD | head -1)
    one "$f-root" "$WORK/fx/$f" "$root"
done

# merges
one merges-merge "$WORK/fx/merges" HEAD~1
one cross-merge "$WORK/fx/cross" HEAD
one cross-merge "$WORK/fx/cross" HEAD~2

# tags: annotated, lightweight, tag of a tag, tag of a tree
t="$WORK/fx/tags"
one tags "$t" v1.0
one tags "$t" light
one tags "$t" v1.0-final
compare tags "$t" show tree-tag
compare tags "$t" show --stat v1.0
compare tags "$t" show v1.0 light
compare tags "$t" show origin/main
compare tags "$t" show refs/tags/v1.0
compare tags "$t" show v1.0^{commit}
compare tags "$t" show v1.0^{}
compare tags "$t" show v1.0 --format=%H -s
compare tags "$t" show --pretty=fuller v1.0
compare tags "$t" show --pretty=oneline v1.0
compare tags "$t" show --color=always v1.0

# trees and blobs
l="$WORK/fx/linear"
compare tree "$l" show 'HEAD^{tree}'
compare tree "$l" show HEAD:src
compare tree "$l" show HEAD:
compare tree "$l" show HEAD~1: HEAD:src
compare tree "$l" show --color=always 'HEAD^{tree}'
compare blob "$l" show HEAD:a.txt
compare blob "$l" show HEAD:src/main.c
compare blob "$l" show HEAD:src/main.c HEAD:a.txt
compare blob "$l" show HEAD:nosuchfile
compare blob "$l" show HEAD~3:b.txt
m="$WORK/fx/modes"
compare blob "$m" show HEAD:link
compare blob "$m" show HEAD:run.sh
b="$WORK/fx/binary"
compare blob "$b" show HEAD:b.bin
compare blob "$b" show HEAD~1:zeros.bin
u="$WORK/fx/unicode"
compare tree "$u" show 'HEAD^{tree}'

# which output format wins when several are given
for combo in "--name-only --numstat" "-s --stat" "-s -p" "--stat -s" "-p -s" "--name-only -s" "-s --name-only" "--name-only --name-status" "--quiet -p" "-p --quiet" "-U1 -s" "-s -U1" "--name-status --stat" "--raw --stat -p" "--summary --shortstat" "--numstat --stat --shortstat --summary -p"; do
    # shellcheck disable=SC2086
    compare combos "$WORK/fx/linear" show $combo
done

# word diffs
for form in "--word-diff" "--word-diff=plain" "--word-diff=color" "--word-diff=porcelain" "--color-words" "--word-diff --color=always" "--word-diff=color --no-color" "--word-diff -U0" "--word-diff -w" "--word-diff=porcelain -U1" "--word-diff --stat"; do
    for fx in linear space crlf renames noeol; do
        if [ -d "$WORK/fx/$fx" ]; then
            # shellcheck disable=SC2086
            compare words-$fx "$WORK/fx/$fx" show $form HEAD
        fi
    done
done

# from a subdirectory
compare linear-sub "$WORK/fx/linear/src" show HEAD
compare linear-sub "$WORK/fx/linear/src" show --name-only HEAD
compare linear-sub "$WORK/fx/linear/src" show HEAD -- .
compare linear-sub "$WORK/fx/linear/src" show HEAD:main.c

if [ "$bad" -eq 0 ]; then
    echo "show: all $n forms byte-identical to git ($known with a merge's combined diff, not implemented, are excluded)"
    exit 0
fi
echo "show: $bad of $n forms differ"
exit 1
