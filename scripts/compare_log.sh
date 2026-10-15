#!/usr/bin/env bash
# `1git log` beside the real `git log`, on disposable fixture repositories
# with fixed identities and dates, compared octet for octet (stdout) and by
# exit status.
#
#   bash scripts/compare_log.sh <1git-binary> [workdir]
#
# The fixtures are scripts/fixtures_look.sh's; each is run through every form
# below, and a few extra forms that need a particular fixture (--follow on
# the renames, -S on the linear history, ...). Nothing here writes outside
# <workdir>. `git` is the oracle; there is no expected-output file to drift.
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

forms() {
    local l=$1 r=$2
    compare "$l" "$r" log
    compare "$l" "$r" log --oneline
    compare "$l" "$r" log --oneline --decorate
    compare "$l" "$r" log --pretty=oneline
    compare "$l" "$r" log --pretty=oneline --abbrev-commit
    compare "$l" "$r" log --oneline --no-abbrev-commit
    compare "$l" "$r" log --oneline --abbrev=10
    compare "$l" "$r" log --format=short
    compare "$l" "$r" log --pretty=med
    compare "$l" "$r" log --no-walk --oneline --all
    compare "$l" "$r" log --decorate=full
    compare "$l" "$r" log --pretty=short
    compare "$l" "$r" log --pretty=full
    compare "$l" "$r" log --pretty=fuller
    compare "$l" "$r" log --pretty=raw
    compare "$l" "$r" log '--format=%H|%h|%T|%t|%P|%p|%an|%ae|%al|%ad|%aD|%ar|%at|%ai|%aI|%as|%cn|%ce|%cd|%cr|%ct|%ci|%cI|%cs|%s|%f|%d|%D|%e|%%|%n'
    compare "$l" "$r" log '--format=%s%n%b%n--%B--'
    compare "$l" "$r" log '--format=%C(red)%h%C(reset) %s'
    compare "$l" "$r" log --color=always '--format=%C(yellow)%h%Creset %C(auto)%d%Creset %s'
    compare "$l" "$r" log '--format=%<(20)%an|%>(20)%an|%<(10,trunc)%s|%>(10,ltrunc)%s|%<(12,mtrunc)%s|%><(15)%an|%x41%x0a'
    compare "$l" "$r" log '--format=%h%+d%n%-b%n% s'
    compare "$l" "$r" log --format=
    compare "$l" "$r" log --pretty=tformat:%h
    compare "$l" "$r" log --pretty=format:%h
    compare "$l" "$r" log --date=iso
    compare "$l" "$r" log --date=iso-strict
    compare "$l" "$r" log --date=short
    compare "$l" "$r" log --date=relative
    compare "$l" "$r" log --date=raw
    compare "$l" "$r" log --date=unix
    compare "$l" "$r" log --date=rfc
    compare "$l" "$r" log '--date=format:%Y/%m/%d %H:%M:%S %a %b %j %p %z'
    compare "$l" "$r" log -1
    compare "$l" "$r" log -2 --oneline
    compare "$l" "$r" log -n 3 --oneline
    compare "$l" "$r" log --skip=1 -2 --oneline
    compare "$l" "$r" log --max-count=0
    compare "$l" "$r" log --reverse --oneline
    compare "$l" "$r" log --reverse -p
    compare "$l" "$r" log -p
    compare "$l" "$r" log -p --oneline
    compare "$l" "$r" log -p -U1
    compare "$l" "$r" log -p -U0 --oneline
    compare "$l" "$r" log -p -w
    compare "$l" "$r" log -p -b
    compare "$l" "$r" log --stat
    compare "$l" "$r" log --stat --oneline
    compare "$l" "$r" log --stat -p
    compare "$l" "$r" log --stat=60,20
    compare "$l" "$r" log --numstat
    compare "$l" "$r" log --shortstat
    compare "$l" "$r" log --name-only
    compare "$l" "$r" log --name-status
    compare "$l" "$r" log --name-status --oneline
    compare "$l" "$r" log --raw
    compare "$l" "$r" log --summary
    compare "$l" "$r" log --stat --summary
    compare "$l" "$r" log --no-renames --name-status
    compare "$l" "$r" log -M30% --name-status
    compare "$l" "$r" log -p --color=always
    compare "$l" "$r" log --stat --color=always
    compare "$l" "$r" log --color=always --oneline --decorate
    compare "$l" "$r" log --color=always
    compare "$l" "$r" log --graph
    compare "$l" "$r" log --graph --oneline
    compare "$l" "$r" log --graph --oneline --decorate
    compare "$l" "$r" log --graph --stat
    compare "$l" "$r" log --graph -p
    compare "$l" "$r" log --graph --all --oneline
    compare "$l" "$r" log --graph --color=always --oneline --decorate
    compare "$l" "$r" log --graph --all --decorate --format='%h %s%n%b'
    compare "$l" "$r" log --graph --first-parent --oneline
    compare "$l" "$r" log --graph --name-status
    compare "$l" "$r" log --all
    compare "$l" "$r" log --all --oneline --decorate
    compare "$l" "$r" log --branches --oneline
    compare "$l" "$r" log --tags --oneline
    compare "$l" "$r" log --first-parent --oneline
    compare "$l" "$r" log --no-merges --oneline
    compare "$l" "$r" log --merges --oneline
    compare "$l" "$r" log --topo-order --oneline
    compare "$l" "$r" log --author=Ada --oneline
    compare "$l" "$r" log --author=nobody --oneline
    compare "$l" "$r" log --author='Ada Author <ada' --oneline
    compare "$l" "$r" log --committer=Cy --oneline
    compare "$l" "$r" log --grep=add --oneline
    compare "$l" "$r" log --grep=ADD -i --oneline
    compare "$l" "$r" log --grep='add\|remove' --oneline
    compare "$l" "$r" log -E --grep='add|remove' --oneline
    compare "$l" "$r" log -F --grep='add' --oneline
    compare "$l" "$r" log --grep=add --invert-grep --oneline
    compare "$l" "$r" log --grep=first --grep=add --all-match --oneline
    compare "$l" "$r" log --since=2023-11-15 --oneline
    compare "$l" "$r" log --until=2023-11-15 --oneline
    compare "$l" "$r" log --since='2023-11-15 06:00:00' --until='2023-11-15 12:00' --oneline
    compare "$l" "$r" log --since=1700010000 --oneline
    compare "$l" "$r" log '--since=2 weeks ago' --oneline
    compare "$l" "$r" log '--until=3 months ago' --oneline
    compare "$l" "$r" log -S"line" --oneline
    compare "$l" "$r" log -Sone --oneline -p
    compare "$l" "$r" log HEAD~1..HEAD --oneline
    compare "$l" "$r" log HEAD~2.. --oneline
    compare "$l" "$r" log ..HEAD --oneline
    compare "$l" "$r" log HEAD...HEAD~1 --oneline
    compare "$l" "$r" log HEAD ^HEAD~1 --oneline
    compare "$l" "$r" log HEAD --not HEAD~2 --oneline
    compare "$l" "$r" log HEAD~1 --oneline
    compare "$l" "$r" log -- a.txt
    compare "$l" "$r" log --oneline -- a.txt src
    compare "$l" "$r" log --oneline -- nosuchpath
    compare "$l" "$r" log -p -- '*.txt'
    compare "$l" "$r" log --stat -- src
    compare "$l" "$r" log --graph --oneline -- a.txt
    compare "$l" "$r" log --oneline --follow -- a.txt
    compare "$l" "$r" log nosuchrev
    compare "$l" "$r" log --bad-option
}

fixtures() {
    local base=$1
    build_all "$base" || exit 1
}

fixtures "$WORK/fx"
for f in linear merges cross renames modes binary empty large tags crlf unicode space orphan links; do
    forms "$f" "$WORK/fx/$f"
done

# forms that need a particular history
compare renames "$WORK/fx/renames" log --follow --oneline -- docs.txt
compare renames "$WORK/fx/renames" log --follow -p -- docs.txt
compare renames "$WORK/fx/renames" log --follow --name-status -- run.sh
compare renames "$WORK/fx/renames" log --oneline -- moved
compare renames "$WORK/fx/renames" log --name-status -M --oneline
compare renames "$WORK/fx/renames" log --name-status -M90% --oneline
compare renames "$WORK/fx/renames" log --stat --oneline
compare linear "$WORK/fx/linear" log -Sbeta --oneline
compare linear "$WORK/fx/linear" log -SZETA -p
compare linear "$WORK/fx/linear" log --author=Ada --grep=change --oneline
compare linear "$WORK/fx/linear" log --until=2023-11-15 --since=2023-11-14 --oneline
compare large "$WORK/fx/large" log --stat --stat-width=40
compare large "$WORK/fx/large" log --stat=200,80
compare large "$WORK/fx/large" log -p --oneline -U5
compare tags "$WORK/fx/tags" log --decorate --oneline v1.0 light
compare tags "$WORK/fx/tags" log --tags --no-walk --oneline

# names with bytes above 127, quoted or not
compare unicode "$WORK/fx/unicode" -c core.quotePath=false log --name-status --oneline
compare unicode "$WORK/fx/unicode" -c core.quotePath=false log --stat --oneline
compare unicode "$WORK/fx/unicode" -c core.quotePath=false log -p --oneline
compare unicode "$WORK/fx/unicode" -c core.quotePath=false log --summary --oneline
compare unicode "$WORK/fx/unicode" log --summary --oneline

# which output format wins when several are given
for combo in "--name-only --numstat" "-s --stat" "-s -p" "--stat -s" "-p -s" "--name-only -s" "-s --name-only" "--name-only --name-status" "--quiet -p" "-p --quiet" "-U1 -s" "-s -U1" "--name-status --stat" "--raw --stat -p" "--summary --shortstat" "--numstat --stat --shortstat --summary -p"; do
    # shellcheck disable=SC2086
    compare combos "$WORK/fx/linear" log $combo
done

# word diffs
for form in "--word-diff" "--word-diff=plain" "--word-diff=color" "--word-diff=porcelain" "--color-words" "--word-diff --color=always" "--word-diff=color --no-color" "--word-diff -U0" "--word-diff -w" "--word-diff=porcelain -U1" "--word-diff --stat"; do
    for fx in linear space crlf renames noeol; do
        if [ -d "$WORK/fx/$fx" ]; then
            # shellcheck disable=SC2086
            compare words-$fx "$WORK/fx/$fx" log -p $form
        fi
    done
done

# a subdirectory as the working directory: paths relative to it
compare linear-sub "$WORK/fx/linear/src" log --oneline -- main.c
compare linear-sub "$WORK/fx/linear/src" log --oneline -- ../a.txt
compare linear-sub "$WORK/fx/linear/src" log --name-only --oneline
compare linear-sub "$WORK/fx/linear/src" log -p --oneline .

if [ "$bad" -eq 0 ]; then
    echo "log: all $n forms byte-identical to git"
    exit 0
fi
echo "log: $bad of $n forms differ"
exit 1
