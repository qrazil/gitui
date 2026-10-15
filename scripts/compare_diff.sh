#!/usr/bin/env bash
# `1git diff` beside the real `git diff`, on disposable fixture repositories
# with fixed identities and dates, compared octet for octet (stdout) and by
# exit status.
#
#   bash scripts/compare_diff.sh <1git-binary> [workdir]
#
# Two kinds of fixture: the histories of scripts/fixtures_look.sh, diffed
# commit against commit (`A B`, `A..B`, `A...B`), and work trees in states
# that only the working-tree forms see (unstaged and staged edits, a file
# staged and edited again, deletions, mode changes, whitespace and line
# ending changes, binary changes, a rename in the index). Nothing here writes
# outside <workdir>. `git` is the oracle; there is no expected-output file.
set -uo pipefail

OURS=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${2:-$(mktemp -d)}
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)

# shellcheck source=fixtures_look.sh
. "$HERE/fixtures_look.sh"

bad=0
n=0

# compare <label> <repo> <args...>
compare() {
    local label=$1 repo=$2
    shift 2
    n=$((n + 1))
    git -C "$repo" "$@" > "$WORK/want" 2> "$WORK/want.err"; local want_rc=$?
    "$OURS" -C "$repo" "$@" > "$WORK/got" 2> "$WORK/got.err"; local got_rc=$?
    if ! cmp -s "$WORK/want" "$WORK/got" || [ $want_rc -ne $got_rc ]; then
        printf '\033[31mdiffer\033[0m %s: %s\n' "$label" "$*"
        printf '       exit: git %s, 1git %s\n' "$want_rc" "$got_rc"
        diff <(sed 's/$/$/' "$WORK/want" | cat -v) <(sed 's/$/$/' "$WORK/got" | cat -v) | head -12 | sed 's/^/       /'
        head -3 "$WORK/got.err" | sed 's/^/       stderr: /'
        bad=$((bad + 1))
    fi
}

# every output form, for one revision selection
shapes() {
    local l=$1 r=$2
    shift 2
    compare "$l" "$r" diff "$@"
    compare "$l" "$r" diff --stat "$@"
    compare "$l" "$r" diff --stat=50,20 "$@"
    compare "$l" "$r" diff --numstat "$@"
    compare "$l" "$r" diff --shortstat "$@"
    compare "$l" "$r" diff --name-only "$@"
    compare "$l" "$r" diff --name-status "$@"
    compare "$l" "$r" diff --raw "$@"
    compare "$l" "$r" diff --summary "$@"
    compare "$l" "$r" diff --stat --summary "$@"
    compare "$l" "$r" diff -p --stat "$@"
    compare "$l" "$r" diff -U0 "$@"
    compare "$l" "$r" diff -U1 "$@"
    compare "$l" "$r" diff -U8 "$@"
    compare "$l" "$r" diff -w "$@"
    compare "$l" "$r" diff -b "$@"
    compare "$l" "$r" diff -w --stat "$@"
    compare "$l" "$r" diff --no-renames "$@"
    compare "$l" "$r" diff -M30% "$@"
    compare "$l" "$r" diff -R "$@"
    compare "$l" "$r" diff -a "$@"
    compare "$l" "$r" diff --full-index "$@"
    compare "$l" "$r" diff --abbrev=12 "$@"
    compare "$l" "$r" diff --no-prefix "$@"
    compare "$l" "$r" diff --src-prefix=x/ --dst-prefix=y/ "$@"
    compare "$l" "$r" diff --color=always "$@"
    compare "$l" "$r" diff --color=always --stat "$@"
    compare "$l" "$r" diff --color=always -w "$@"
    compare "$l" "$r" diff --color=never "$@"
    compare "$l" "$r" diff --exit-code "$@"
    compare "$l" "$r" diff --quiet "$@"
    compare "$l" "$r" diff --exit-code --stat "$@"
    compare "$l" "$r" diff -z --name-only "$@"
    compare "$l" "$r" diff -z --numstat "$@"
    compare "$l" "$r" diff -z --name-status "$@"
    compare "$l" "$r" diff --diff-filter=AM --name-status "$@"
    compare "$l" "$r" diff --diff-filter=d --name-status "$@"
}

# a history fixture: pairs of commits
history() {
    local l=$1 r=$2
    shapes "$l" "$r" HEAD~1 HEAD
    shapes "$l" "$r" HEAD~2..HEAD
    compare "$l" "$r" diff HEAD~1
    compare "$l" "$r" diff HEAD~1...HEAD
    compare "$l" "$r" diff HEAD...HEAD~1
    compare "$l" "$r" diff HEAD HEAD~1
    compare "$l" "$r" diff --cached HEAD~1
    compare "$l" "$r" diff --stat HEAD~1 HEAD -- a.txt
    compare "$l" "$r" diff HEAD~1 HEAD -- a.txt src
    compare "$l" "$r" diff HEAD~1 HEAD -- '*.txt'
    compare "$l" "$r" diff HEAD~1 HEAD -- ':!a.txt'
    compare "$l" "$r" diff HEAD~1 HEAD -- nosuchpath
    compare "$l" "$r" diff
    compare "$l" "$r" diff --cached
    compare "$l" "$r" diff nosuchrev
    compare "$l" "$r" diff HEAD nosuchfile
    compare "$l" "$r" diff --bad-option
    compare "$l" "$r" diff HEAD~100 HEAD
}

fixtures_dir="$WORK/fx"
build_all "$fixtures_dir" || exit 1
for f in linear merges cross renames modes binary empty large tags crlf unicode space orphan links; do
    history "$f" "$fixtures_dir/$f"
done
shapes dirty "$fixtures_dir/dirty"
shapes dirty-cached "$fixtures_dir/dirty" --cached
shapes dirty-head "$fixtures_dir/dirty" HEAD
shapes dirty-staged "$fixtures_dir/dirty" --staged
compare dirty "$fixtures_dir/dirty" diff -- a.txt
compare dirty "$fixtures_dir/dirty" diff -- dir
compare dirty "$fixtures_dir/dirty" diff HEAD -- b.txt dir/c.txt
compare dirty "$fixtures_dir/dirty" diff --cached -- n.txt s.txt
compare dirty "$fixtures_dir/dirty" diff untracked.txt
compare dirty "$fixtures_dir/dirty" diff --name-only
compare dirty "$fixtures_dir/dirty/dir" diff
compare dirty "$fixtures_dir/dirty/dir" diff --name-only
compare dirty "$fixtures_dir/dirty/dir" diff -- .
compare dirty "$fixtures_dir/dirty/dir" diff -- ../a.txt
compare dirty "$fixtures_dir/dirty/dir" diff HEAD -- c.txt

# work trees in particular states
wt() {
    local name=$1
    rm -rf "${WORK:?}/wt/$name"
    mkdir -p "$WORK/wt/$name"
    cd "$WORK/wt/$name" || exit 1
    g init -q .
}

# whitespace-only edits
wt whitespace
printf 'a  b\nc d\n\te\n' > w.txt
printf 'int f(void)\n{\n  return 1;\n}\n' > code.c
g add -A; commit_at base
printf 'a b\nc  d \n    e\n' > w.txt
printf 'int f(void)\n{\n\treturn 1;\n}\n' > code.c
shapes whitespace "$WORK/wt/whitespace"
shapes whitespace-staged "$WORK/wt/whitespace" --cached

# line endings
wt endings
printf 'one\ntwo\nthree\n' > unix.txt
printf 'one\r\ntwo\r\nthree\r\n' > dos.txt
g add -A; commit_at base
printf 'one\r\ntwo\r\nthree\r\n' > unix.txt
printf 'one\ntwo\nthree\n' > dos.txt
shapes endings "$WORK/wt/endings"

# binary and mode changes
wt binary-modes
printf 'text\n' > t.txt
printf '\000\001\002' > b.bin
printf '#!/bin/sh\n' > run.sh
chmod +x run.sh
g add -A; commit_at base
printf '\000\001\002\003' > b.bin
chmod -x run.sh
chmod +x t.txt
printf 'new binary \000\n' > nb.bin
g add nb.bin
shapes binary-modes "$WORK/wt/binary-modes"
shapes binary-modes-head "$WORK/wt/binary-modes" HEAD

# a rename in the index, deletions, a file staged and edited again
wt staged-rename
for i in 1 2 3 4 5 6 7 8 9 10; do printf 'line %s\n' "$i"; done > old.txt
printf 'keep\n' > keep.txt
printf 'gone\n' > gone.txt
g add -A; commit_at base
g mv old.txt new.txt
printf 'line 1\nline 2 edited\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\nline 10\n' > new.txt
g add -A
rm gone.txt
printf 'keep\nmore\n' > keep.txt
shapes staged-rename "$WORK/wt/staged-rename"
shapes staged-rename-cached "$WORK/wt/staged-rename" --cached
shapes staged-rename-head "$WORK/wt/staged-rename" HEAD

# no newline at the end of file, empty files
wt noeol
printf 'x' > no.txt
: > empty.txt
printf 'y\n' > a.txt
g add -A; commit_at base
printf 'x\n' > no.txt
printf 'now\n' > empty.txt
printf 'y' > a.txt
shapes noeol "$WORK/wt/noeol"

# a file in an unborn repository
wt unborn
printf 'one\n' > a.txt
g add a.txt
compare unborn "$WORK/wt/unborn" diff --cached
compare unborn "$WORK/wt/unborn" diff
compare unborn "$WORK/wt/unborn" diff --cached --stat
compare unborn "$WORK/wt/unborn" diff HEAD

# a large file with changes in several places
wt bigedit
for i in $(seq 1 3000); do printf 'line %d of the big file\n' "$i"; done > big.txt
g add -A; commit_at base
awk 'NR==5 || NR==700 || NR==1500 || NR==2998 { print "EDITED " $0; next } NR==1000 { next } { print } NR==2000 { print "added after 2000" }' big.txt > big.new
mv big.new big.txt
shapes bigedit "$WORK/wt/bigedit"

# symbolic links: to a file, to a directory, dangling, retargeted, a file
# replaced by a link and the reverse, a link staged and then retargeted
wt symlinks
mkdir sub
printf 'target\n' > t.txt
printf 'inner\n' > sub/i.txt
ln -s t.txt to-file
ln -s sub to-dir
ln -s nowhere dangling
ln -s t.txt retarget
ln -s t.txt becomes-file
printf 'was a file\n' > becomes-link
ln -s t.txt staged-link
ln -s t.txt gone-link
ln -s 'a b/c' spaced
ln -s sub/i.txt in-sub
g add -A; commit_at base
ln -sfn sub/i.txt retarget
ln -sfn nowhere to-file
rm becomes-file; printf 'now a file\n' > becomes-file
rm becomes-link; ln -s t.txt becomes-link
ln -sfn sub/i.txt staged-link
g add staged-link
ln -sfn t.txt staged-link
rm gone-link
ln -sfn 'a b/d' spaced
rm to-dir; mkdir to-dir; printf 'dir now\n' > to-dir/x
ln -s t.txt new-link
ln -s newdir new-dangling
g add new-link
shapes symlinks "$WORK/wt/symlinks"
shapes symlinks-cached "$WORK/wt/symlinks" --cached
shapes symlinks-head "$WORK/wt/symlinks" HEAD
compare symlinks "$WORK/wt/symlinks" diff -- retarget to-file
compare symlinks "$WORK/wt/symlinks" diff --name-status
compare symlinks "$WORK/wt/symlinks" diff --raw HEAD
compare symlinks "$WORK/wt/symlinks" diff --summary HEAD
compare symlinks "$WORK/wt/symlinks" diff --numstat
compare symlinks "$WORK/wt/symlinks" diff -R
compare symlinks "$WORK/wt/symlinks" diff --word-diff
g add -A
compare symlinks-staged "$WORK/wt/symlinks" diff --cached
compare symlinks-staged "$WORK/wt/symlinks" diff --cached --raw
compare symlinks-staged "$WORK/wt/symlinks" status --short
compare symlinks-staged "$WORK/wt/symlinks" diff
commit_at second
compare symlinks-history "$WORK/wt/symlinks" diff HEAD~1 HEAD
compare symlinks-history "$WORK/wt/symlinks" diff HEAD~1 HEAD --stat --summary
compare symlinks-history "$WORK/wt/symlinks" diff HEAD~1 HEAD --raw
compare symlinks-history "$WORK/wt/symlinks" show HEAD

# a conflicted merge: both sides edit, both add, one deletes and the other
# edits (each way), a mode change, a binary conflict, a resolved path left
# in the work tree, and a deleted conflicted file
wt conflict
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'line %s\n' "$i"; done > f.txt
printf 'x\n' > del-us.txt
printf 'y\n' > del-them.txt
printf 'm\n' > mode.sh
printf 'bin\000base\n' > data.bin
printf 'ok\n' > clean.txt
printf 'r\n' > resolved.txt
printf 'gone\n' > gone.txt
printf 'ln\n' > ln-target
ln -s ln-target link
g add -A; commit_at base
g checkout -q -b other
sed -i 's/^line 2$/line 2 other/; s/^line 11$/line 11 other/' f.txt
printf 'other add\n' > both-add.txt
printf 'y changed\n' > del-them.txt
g rm -q del-us.txt
chmod +x mode.sh
printf 'bin\000other\n' > data.bin
printf 'r other\n' > resolved.txt
printf 'gone other\n' > gone.txt
rm link; ln -s other-target link
g add -A; commit_at other
g checkout -q main
sed -i 's/^line 2$/line 2 main/; s/^line 6$/line 6 main/' f.txt
printf 'main add\n' > both-add.txt
printf 'x changed\n' > del-us.txt
g rm -q del-them.txt
printf 'bin\000main\n' > data.bin
printf 'r main\n' > resolved.txt
g rm -q gone.txt
rm link; ln -s main-target link
g add -A; commit_at main
g merge other > /dev/null 2>&1
printf 'r resolved\n' > resolved.txt
echo more >> clean.txt
shapes conflict "$WORK/wt/conflict"
shapes conflict-cached "$WORK/wt/conflict" --cached
shapes conflict-head "$WORK/wt/conflict" HEAD
shapes conflict-cc "$WORK/wt/conflict" --cc
shapes conflict-c "$WORK/wt/conflict" -c
compare conflict "$WORK/wt/conflict" diff -- f.txt
compare conflict "$WORK/wt/conflict" diff --cc -- f.txt data.bin
compare conflict "$WORK/wt/conflict" diff -c -U1
compare conflict "$WORK/wt/conflict" diff -U0
compare conflict "$WORK/wt/conflict" diff --no-diff-merges
compare conflict "$WORK/wt/conflict" diff -w
compare conflict "$WORK/wt/conflict" diff --color=always
compare conflict "$WORK/wt/conflict" diff -z --raw
compare conflict "$WORK/wt/conflict" diff -c -z --name-only
compare conflict "$WORK/wt/conflict" diff --cached HEAD --raw
compare conflict "$WORK/wt/conflict" diff MERGE_HEAD
compare conflict "$WORK/wt/conflict" diff HEAD MERGE_HEAD
compare conflict "$WORK/wt/conflict" diff --exit-code
compare conflict "$WORK/wt/conflict" diff --quiet
compare conflict "$WORK/wt/conflict/." diff
rm "$WORK/wt/conflict/f.txt"
compare conflict-deleted "$WORK/wt/conflict" diff
compare conflict-deleted "$WORK/wt/conflict" diff --cc --raw
compare conflict-deleted "$WORK/wt/conflict" diff --stat
printf 'line 1\nline 3\n' > "$WORK/wt/conflict/f.txt"
compare conflict-rewritten "$WORK/wt/conflict" diff
compare conflict-rewritten "$WORK/wt/conflict" diff -U0
printf '' > "$WORK/wt/conflict/f.txt"
compare conflict-empty "$WORK/wt/conflict" diff
chmod +x "$WORK/wt/conflict/both-add.txt"
compare conflict-mode "$WORK/wt/conflict" diff

# which output format wins when several are given
for combo in "--name-only --numstat" "-s --stat" "-s -p" "--stat -s" "-p -s" "--name-only -s" "-s --name-only" "--name-only --name-status" "--quiet -p" "-p --quiet" "-U1 -s" "-s -U1" "--name-status --stat" "--raw --stat -p" "--summary --shortstat" "--numstat --stat --shortstat --summary -p"; do
    # shellcheck disable=SC2086
    compare combos "$WORK/fx/linear" diff $combo
done

# word diffs
for form in "--word-diff" "--word-diff=plain" "--word-diff=color" "--word-diff=porcelain" "--color-words" "--word-diff --color=always" "--word-diff=color --no-color" "--word-diff -U0" "--word-diff -w" "--word-diff=porcelain -U1" "--word-diff --stat"; do
    for fx in linear space crlf renames noeol; do
        if [ -d "$WORK/fx/$fx" ]; then
            # shellcheck disable=SC2086
            compare words-$fx "$WORK/fx/$fx" diff $form HEAD~1 HEAD
        fi
    done
done

# configuration: diff.noprefix, diff.renames, diff.context, color.diff, core.abbrev
compare history-config "$fixtures_dir/renames" -c diff.noprefix=true diff HEAD~3 HEAD
compare history-config "$fixtures_dir/renames" -c diff.renames=false diff --name-status HEAD~3 HEAD
compare history-config "$fixtures_dir/renames" -c diff.context=1 diff HEAD~3 HEAD
compare history-config "$fixtures_dir/renames" -c color.diff=always diff HEAD~3 HEAD
compare history-config "$fixtures_dir/renames" -c color.ui=always -c color.diff.meta=blue -c color.diff.new='green bold' -c color.diff.old=magenta -c color.diff.frag=yellow diff HEAD~3 HEAD
compare history-config "$fixtures_dir/renames" -c core.abbrev=10 diff HEAD~3 HEAD
compare history-config "$fixtures_dir/renames" -c diff.statNameWidth=12 diff --stat HEAD~3 HEAD
compare history-config "$fixtures_dir/renames" -c diff.statGraphWidth=5 diff --stat HEAD~3 HEAD
compare history-config "$fixtures_dir/unicode" -c core.quotePath=false diff --stat --summary HEAD~2 HEAD
compare history-config "$fixtures_dir/unicode" -c core.quotePath=false diff HEAD~2 HEAD
compare history-config "$fixtures_dir/unicode" -c core.quotePath=false diff --name-only --numstat HEAD~2 HEAD
compare history-config "$fixtures_dir/unicode" -c core.quotePath=false diff --raw HEAD~2 HEAD
compare history-config "$fixtures_dir/unicode" diff --raw HEAD~2 HEAD
compare history-config "$fixtures_dir/unicode" diff -z --name-status HEAD~2 HEAD
compare history-config "$fixtures_dir/unicode" diff -z --stat HEAD~2 HEAD

if [ "$bad" -eq 0 ]; then
    echo "diff: all $n forms byte-identical to git"
    exit 0
fi
echo "diff: $bad of $n forms differ"
exit 1
