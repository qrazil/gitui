#!/usr/bin/env bash
# The change commands of `1git` beside the real `git`, on pairs of identical
# disposable repositories.
#
#   bash scripts/compare_write.sh <1git-binary> [workdir] [group...]
#
# groups: add rm mv restore reset commit switch checkout branch tag gerrit misc patch icase
#         (default: all)
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
# sed -i that BSD sed (macOS) also takes (it wants a suffix; GNU takes none)
sedi() { local f="${@: -1}"; sed "${@:1:$#-1}" "$f" > "$f.sedi" && mv "$f.sedi" "$f"; }

OURS=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${2:-$(mktemp -d)}
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
shift
shift || true
GROUPS_WANTED=${*:-add rm mv restore reset commit switch checkout branch tag gerrit misc patch icase}

# --- group icase on a real case-insensitive volume ---------------------------------------
# macOS runs the group natively on APFS (case-insensitive: lstat and open of
# the other spelling succeed, readdir has the one on-disk spelling). A Linux
# 6.13+ with unprivileged user namespaces gets the same kind of volume from a
# tmpfs mounted with `casefold` (chattr +F on its root), so the group is run a
# second time inside `unshare -Urm` on it; this is a real folding volume, not
# the hard-link stand-in the case-sensitive run below uses (see the notes at
# the group). Where neither exists the group runs on the work directory only
# and the real-volume behaviours are not asserted there.
if [ -z "${ICASE_NS:-}" ] && [[ " $GROUPS_WANTED " == *" icase "* ]] \
    && command -v unshare > /dev/null 2>&1 && command -v chattr > /dev/null 2>&1; then
    cf=$WORK/casefold
    mkdir -p "$cf"
    if unshare -Urm sh -c 'mount -t tmpfs -o casefold tmpfs "$1" && chattr +F "$1" && : > "$1/Zz" && [ -e "$1/zZ" ]' _ "$cf" 2> /dev/null; then
        echo "compare_write: group icase on a casefold tmpfs (real insensitive volume)"
        ICASE_NS=1 unshare -Urm bash -c 'mount -t tmpfs -o casefold tmpfs "$1" && chattr +F "$1" && exec bash "$2" "$3" "$1" icase' _ "$cf" "$HERE/compare_write.sh" "$OURS"
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

# files with several hunks (some splittable), a short one, a mode change, a
# deletion, a file without a final newline
fx_hunks() {
    new_repo "$1"
    local i
    (echo "int func_a(void)"; for i in $(seq 1 40); do echo "  line $i"; done) > s.c
    for i in $(seq 1 30); do echo "line $i"; done > f.txt
    printf 'one\ntwo\n' > g.txt
    printf 'alpha\nbeta' > noeol.txt
    printf 'run\n' > run.sh
    printf 'gone\n' > del.txt
    mkdir sub
    printf 'x\ny\nz\n' > sub/in.txt
    g add -A
    commit_at "base"
    g switch -q -c other
    printf 'one\nTWO\n' > g.txt
    printf 'line 1\n' > f.txt
    g commit -qam "other"
    g switch -q main
    sedi 's/^  line 3$/  line 3 X/; s/^  line 8$/  line 8 X/; s/^  line 9$/  line 9 X/; s/^  line 33$/  line 33 X/; s/^  line 38$/  line 38 X/' s.c
    sedi 's/^line 3$/line 3 X/; s/^line 4$/line 4 X/; s/^line 15$/line 15 X/; s/^line 28$/line 28 X/' f.txt
    printf 'one\nTWO\nthree\n' > g.txt
    printf 'alpha\nBETA' > noeol.txt
    chmod +x run.sh
    rm del.txt
    printf 'x\nY\nz\n' > sub/in.txt
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
        for f in MERGE_HEAD MERGE_MSG ORIG_HEAD CHERRY_PICK_HEAD REVERT_HEAD SQUASH_MSG; do
            if [ -e ".git/$f" ]; then echo "$f: $(cat ".git/$f" | head -c 200 | tr '\n' '|')"; fi
        done
        echo "## tree"
        find . -path ./.git -prune -o \( -type f -o -type l \) -print | LC_ALL=C sort | while read -r f; do
            if [ -L "$f" ]; then echo "L $f"; else printf '%s %s %s\n' "$(stat -c %a "$f")" "$f" "$(sha1sum < "$f" | cut -c1-12)"; fi
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
    n=$((n + 1))
    local a=$WORK/case-a b=$WORK/case-b
    rm -rf "$a" "$b"
    run_side git "$a" "$fixture" "$setup" "$script" "$WORK/log-a"
    run_side "$OURS" "$b" "$fixture" "$setup" "$script" "$WORK/log-b"
    dump_state "$a" > "$WORK/dump-a" 2>&1
    dump_state "$b" > "$WORK/dump-b" 2>&1
    local failed=0
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

# --- add ----------------------------------------------------------------------------------

if wanted add; then
    case_ "add: one file" fx_base 'echo more >> a.txt' 'G add a.txt'
    case_ "add: two files and a new one" fx_base 'echo more >> a.txt; echo n > new.txt; echo m >> b.txt' 'G add a.txt new.txt'
    case_ "add: dot" fx_base 'echo more >> a.txt; echo n > new.txt; rm b.txt; echo x >> dir/c.txt' 'G add .'
    case_ "add: -A" fx_base 'echo more >> a.txt; echo n > new.txt; rm b.txt; mkdir newdir; echo z > newdir/z' 'G add -A'
    case_ "add: --all" fx_base 'rm b.txt; echo n > new.txt' 'G add --all'
    case_ "add: -u skips untracked" fx_base 'echo more >> a.txt; echo n > new.txt; rm b.txt' 'G add -u'
    case_ "add: --update with path" fx_base 'echo more >> a.txt; echo x >> dir/c.txt' 'G add --update dir'
    case_ "add: deletion by name" fx_base 'rm b.txt' 'G add b.txt'
    case_ "add: directory" fx_base 'echo n > dir/new.txt; echo m >> dir/sub/d.txt; mkdir dir/deep; echo q > dir/deep/q' 'G add dir'
    case_ "add: from a subdirectory" fx_base 'echo n > dir/new.txt; echo m >> a.txt' 'cd dir; G add .; G add ../a.txt'
    case_ "add: -A from a subdirectory covers everything" fx_base 'echo n > dir/new.txt; echo m >> a.txt' 'cd dir; G add -A'
    case_ "add: -u from a subdirectory covers everything" fx_base 'echo m >> a.txt; echo m >> dir/c.txt' 'cd dir; G add -u'
    case_ "add: no match" fx_base 'echo n > new.txt' 'G add nope; G add new.txt nope'
    case_ "add: nothing specified" fx_base 'echo n > new.txt' 'G add'
    case_ "add: dry run" fx_base 'echo n > new.txt; echo m >> a.txt; rm b.txt' 'G add -n .; G add --dry-run -A'
    case_ "add: verbose" fx_base 'echo n > new.txt; echo m >> a.txt; rm b.txt' 'G add -v .'
    case_ "add: verbose from a subdirectory" fx_base 'echo n > dir/new.txt' 'cd dir; G add -v .'
    case_ "add: unchanged is silent" fx_base ':' 'G add a.txt; G add -v a.txt'
    case_ "add: executable bit" fx_base 'chmod +x a.txt; chmod -x exec.sh' 'G add a.txt exec.sh'
    case_ "add: new executable" fx_base 'printf "#!/bin/sh\n" > run.sh; chmod +x run.sh' 'G add run.sh'
    case_ "add: mode only change by -u" fx_base 'chmod +x b.txt' 'G add -u'
    case_ "add: filemode off keeps modes" fx_base 'git config core.filemode false; chmod +x a.txt; echo m >> exec.sh; printf "#!/bin/sh\n" > run.sh; chmod +x run.sh' 'G add -A'
    case_ "add: --chmod=+x" fx_base 'echo n > new.txt' 'G add --chmod=+x new.txt; G add --chmod=-x exec.sh'
    case_ "add: spaces and unicode" fx_base 'echo m >> "sp ace.txt"; echo m >> "ünï.txt"; echo n > "new ü.txt"' 'G add "sp ace.txt" "ünï.txt" "new ü.txt"'
    case_ "add: unicode directory tree" fx_unicode 'echo m >> "dír ectory/fïle one.txt"; echo n > "日本語2.txt"' 'G add -A'
    case_ "add: ignored file is refused" fx_ignore ':' 'G add debug.log'
    case_ "add: ignored file among others" fx_ignore ':' 'G add debug.log new.txt'
    case_ "add: ignored by -f" fx_ignore ':' 'G add -f debug.log'
    case_ "add: dot skips ignored" fx_ignore ':' 'G add .'
    case_ "add: -f dot takes ignored" fx_ignore ':' 'G add -f .'
    case_ "add: ignored directory named" fx_ignore ':' 'G add build'
    case_ "add: glob" fx_base 'echo n > one.c; echo m > two.c; echo o > three.h' 'G add "*.c"'
    case_ "add: glob matching nothing" fx_base 'echo n > one.c' 'G add "*.zzz"'
    case_ "add: resolves a conflict" fx_conflict 'printf "resolved\n" > f.txt' 'G add f.txt'
    case_ "add: resolves a deletion in a conflict" fx_conflict 'rm f.txt' 'G add f.txt'
    case_ "add: -A with a conflict" fx_conflict 'printf "resolved\n" > f.txt; echo n > new.txt' 'G add -A'
    case_ "add: -u with a conflict" fx_conflict 'printf "resolved\n" > f.txt' 'G add -u'
    case_ "add: empty repository" fx_empty ':' 'G add x.txt'
    case_ "add: empty repository dot" fx_empty 'mkdir d; echo y > d/y' 'G add .'
    case_ "add: file replaces directory" fx_base 'rm -r dir; echo f > dir' 'G add -A'
    case_ "add: directory replaces file" fx_base 'rm b.txt; mkdir b.txt; echo f > b.txt/inner' 'G add -A'
    case_ "add: CRLF kept" fx_crlf 'printf "one\r\ntwo\r\nthree\r\n" > win.txt; printf "new\r\n" > fresh.txt' 'G add -A'
    case_ "add: empty file" fx_base ': > empty.txt' 'G add empty.txt'
    case_ "add: binary file" fx_base 'printf "\0\1\2\377" > bin.dat' 'G add bin.dat'
    case_ "add: --ignore-removal" fx_base 'rm b.txt; echo n > new.txt' 'G add --ignore-removal .'
    case_ "add: unknown option" fx_base ':' 'G add --frobnicate a.txt'
    case_ "add: -- separator" fx_base 'echo n > ./-dash' 'G add -- -dash'
    case_ "add: all with pathspec" fx_base 'echo n > dir/n; echo m >> a.txt' 'G add -A dir'
    case_ "add: path outside the tree" fx_base ':' 'G add ../x'
fi

# --- rm -----------------------------------------------------------------------------------

if wanted rm; then
    case_ "rm: a file" fx_base ':' 'G rm b.txt'
    case_ "rm: several" fx_base ':' 'G rm b.txt a.txt'
    case_ "rm: directory needs -r" fx_base ':' 'G rm dir'
    case_ "rm: -r directory" fx_base ':' 'G rm -r dir'
    case_ "rm: -r removes empty parents" fx_base ':' 'G rm -r dir/sub'
    case_ "rm: --cached keeps the file" fx_base ':' 'G rm --cached b.txt'
    case_ "rm: --cached -r" fx_base ':' 'G rm --cached -r dir'
    case_ "rm: local modifications refused" fx_base 'echo m >> a.txt' 'G rm a.txt'
    case_ "rm: local modifications with -f" fx_base 'echo m >> a.txt' 'G rm -f a.txt'
    case_ "rm: staged changes refused" fx_base 'echo m >> a.txt; git add a.txt' 'G rm a.txt'
    case_ "rm: staged and local refused" fx_base 'echo m >> a.txt; git add a.txt; echo n >> a.txt' 'G rm a.txt'
    case_ "rm: staged and local with --cached refused" fx_base 'echo m >> a.txt; git add a.txt; echo n >> a.txt' 'G rm --cached a.txt'
    case_ "rm: staged changes with --cached" fx_base 'echo m >> a.txt; git add a.txt' 'G rm --cached a.txt'
    case_ "rm: local modifications with --cached" fx_base 'echo m >> a.txt' 'G rm --cached a.txt'
    case_ "rm: newly added file refused" fx_base 'echo n > new.txt; git add new.txt' 'G rm new.txt'
    case_ "rm: newly added file with --cached" fx_base 'echo n > new.txt; git add new.txt' 'G rm --cached new.txt'
    case_ "rm: newly added with -f" fx_base 'echo n > new.txt; git add new.txt' 'G rm -f new.txt'
    case_ "rm: no match" fx_base ':' 'G rm nope'
    case_ "rm: ignore-unmatch" fx_base ':' 'G rm --ignore-unmatch nope'
    case_ "rm: ignore-unmatch with a match" fx_base ':' 'G rm --ignore-unmatch nope b.txt'
    case_ "rm: untracked file is no match" fx_base 'echo n > new.txt' 'G rm new.txt'
    case_ "rm: dry run" fx_base ':' 'G rm -n b.txt; G rm --dry-run -r dir'
    case_ "rm: quiet" fx_base ':' 'G rm -q b.txt'
    case_ "rm: already deleted from the work tree" fx_base 'rm b.txt' 'G rm b.txt'
    case_ "rm: from a subdirectory" fx_base ':' 'cd dir; G rm c.txt ../b.txt'
    case_ "rm: glob" fx_base ':' 'G rm "dir/*.txt"'
    case_ "rm: glob crosses directories" fx_base ':' 'G rm "*.txt"'
    case_ "rm: spaces and unicode" fx_base ':' 'G rm "sp ace.txt" "ünï.txt"'
    case_ "rm: executable file" fx_base ':' 'G rm exec.sh'
    case_ "rm: unmerged path" fx_conflict ':' 'G rm f.txt'
    case_ "rm: unmerged path --cached" fx_conflict ':' 'G rm --cached f.txt'
    case_ "rm: in an empty repository" fx_empty 'git add x.txt' 'G rm x.txt; G rm --cached x.txt'
    case_ "rm: no arguments" fx_base ':' 'G rm'
    case_ "rm: dot needs -r" fx_base ':' 'G rm .'
    case_ "rm: dot -r" fx_base ':' 'G rm -r .'
fi

# --- mv -----------------------------------------------------------------------------------

if wanted mv; then
    case_ "mv: rename" fx_base ':' 'G mv b.txt c2.txt'
    case_ "mv: verbose" fx_base ':' 'G mv -v b.txt c2.txt'
    case_ "mv: into a directory" fx_base ':' 'G mv b.txt dir'
    case_ "mv: several into a directory" fx_base ':' 'G mv a.txt b.txt dir/sub'
    case_ "mv: several into a non directory" fx_base ':' 'G mv a.txt b.txt nothere'
    case_ "mv: a directory" fx_base ':' 'G mv dir moved'
    case_ "mv: a directory into a directory" fx_base ':' 'G mv dir/sub .'
    case_ "mv: directory into itself" fx_base ':' 'G mv dir dir/sub'
    case_ "mv: destination exists" fx_base ':' 'G mv a.txt b.txt'
    case_ "mv: destination exists with -f" fx_base ':' 'G mv -f a.txt b.txt'
    case_ "mv: bad source" fx_base ':' 'G mv nope x'
    case_ "mv: untracked source" fx_base 'echo n > new.txt' 'G mv new.txt other.txt'
    case_ "mv: skip errors with -k" fx_base 'echo n > new.txt' 'G mv -k new.txt nope b.txt c.txt2'
    case_ "mv: dry run" fx_base ':' 'G mv -n b.txt c2.txt'
    case_ "mv: destination directory missing" fx_base ':' 'G mv b.txt nodir/b.txt'
    case_ "mv: from a subdirectory" fx_base ':' 'cd dir; G mv c.txt ../c-moved.txt'
    case_ "mv: keeps staged and local changes" fx_base 'echo m >> a.txt; git add a.txt; echo n >> a.txt' 'G mv a.txt z.txt'
    case_ "mv: spaces and unicode" fx_base ':' 'G mv "sp ace.txt" "new ü.txt"'
    case_ "mv: executable keeps its mode" fx_base ':' 'G mv exec.sh run.sh'
    case_ "mv: unmerged source" fx_conflict ':' 'G mv f.txt g.txt'
    case_ "mv: to the same name" fx_base ':' 'G mv a.txt a.txt'
    case_ "mv: no arguments" fx_base ':' 'G mv a.txt'
fi

# --- restore ----------------------------------------------------------------------------

if wanted restore; then
    case_ "restore: worktree from the index" fx_base 'echo m >> a.txt' 'G restore a.txt'
    case_ "restore: deleted file" fx_base 'rm b.txt' 'G restore b.txt'
    case_ "restore: directory" fx_base 'echo m >> dir/c.txt; rm dir/sub/d.txt; echo u > dir/untracked' 'G restore dir'
    case_ "restore: dot" fx_base 'echo m >> a.txt; rm b.txt; echo u > untracked' 'G restore .'
    case_ "restore: --worktree explicit" fx_base 'echo m >> a.txt' 'G restore --worktree a.txt'
    case_ "restore: -W" fx_base 'echo m >> a.txt' 'G restore -W a.txt'
    case_ "restore: --staged" fx_base 'echo m >> a.txt; git add a.txt' 'G restore --staged a.txt'
    case_ "restore: -S keeps the work tree" fx_base 'echo m >> a.txt; git add a.txt' 'G restore -S a.txt'
    case_ "restore: --staged a new file" fx_base 'echo n > new.txt; git add new.txt' 'G restore --staged new.txt'
    case_ "restore: --staged a deletion" fx_base 'git rm -q b.txt' 'G restore --staged b.txt'
    case_ "restore: --staged dot" fx_base 'echo m >> a.txt; echo n > new.txt; git add -A; git rm -q --cached b.txt' 'G restore --staged .'
    case_ "restore: --staged --worktree" fx_base 'echo m >> a.txt; git add a.txt; echo n >> a.txt' 'G restore --staged --worktree a.txt'
    case_ "restore: --source=HEAD~1" fx_base ':' 'G restore --source=HEAD~1 a.txt'
    case_ "restore: --source=side with paths" fx_base ':' 'G restore --source=side b.txt a.txt'
    case_ "restore: -s HEAD~1 --staged" fx_base ':' 'G restore -s HEAD~1 --staged a.txt'
    case_ "restore: --source removes files the source lacks" fx_base 'echo n > new.txt; git add new.txt' 'G restore --source=HEAD~1 --worktree .'
    case_ "restore: --source=side dot" fx_base ':' 'G restore --source=side .'
    case_ "restore: --source=side --staged --worktree dot" fx_base ':' 'G restore --source=side -S -W .'
    case_ "restore: no match" fx_base ':' 'G restore nope'
    case_ "restore: untracked file is no match" fx_base 'echo n > new.txt' 'G restore new.txt'
    case_ "restore: no paths" fx_base ':' 'G restore'
    case_ "restore: unmerged path" fx_conflict ':' 'G restore f.txt'
    case_ "restore: unmerged path --ours" fx_conflict ':' 'G restore --ours f.txt'
    case_ "restore: unmerged path --theirs" fx_conflict ':' 'G restore --theirs f.txt'
    case_ "restore: unmerged path --staged" fx_conflict ':' 'G restore --staged f.txt'
    case_ "restore: unmerged path from a source" fx_conflict ':' 'G restore --source=HEAD f.txt'
    case_ "restore: executable bit comes back" fx_base 'chmod -x exec.sh' 'G restore exec.sh'
    case_ "restore: from a subdirectory" fx_base 'echo m >> dir/c.txt; echo m >> a.txt' 'cd dir; G restore c.txt ../a.txt'
    case_ "restore: dot in a subdirectory" fx_base 'echo m >> dir/c.txt; echo m >> a.txt' 'cd dir; G restore .'
    case_ "restore: spaces and unicode" fx_base 'echo m >> "sp ace.txt"; rm "ünï.txt"' 'G restore "sp ace.txt" "ünï.txt"'
    case_ "restore: CRLF" fx_crlf 'printf "x\n" > win.txt' 'G restore win.txt'
    case_ "restore: glob" fx_base 'echo m >> a.txt; echo m >> b.txt' 'G restore "*.txt"'
    case_ "restore: in an empty repository" fx_empty 'git add x.txt' 'G restore --staged x.txt'
    case_ "restore: quiet" fx_base 'echo m >> a.txt' 'G restore -q a.txt'
fi

# --- reset --------------------------------------------------------------------------------

if wanted reset; then
    case_ "reset: mixed to HEAD~1" fx_base ':' 'G reset HEAD~1'
    case_ "reset: default is mixed" fx_base 'echo m >> a.txt' 'G reset'
    case_ "reset: --mixed with local changes lists them" fx_base 'echo m >> a.txt; rm b.txt' 'G reset --mixed HEAD'
    case_ "reset: soft" fx_base ':' 'G reset --soft HEAD~1'
    case_ "reset: soft keeps staged changes" fx_base 'echo m >> a.txt; git add a.txt' 'G reset --soft HEAD~1'
    case_ "reset: hard" fx_base 'echo m >> a.txt; echo n > untracked.txt' 'G reset --hard HEAD~1'
    case_ "reset: hard with no argument" fx_base 'echo m >> a.txt; git add a.txt; rm b.txt' 'G reset --hard'
    case_ "reset: hard removes added files" fx_base 'echo n > new.txt; git add new.txt' 'G reset --hard HEAD'
    case_ "reset: hard to another branch" fx_base ':' 'G reset --hard side'
    case_ "reset: hard restores a deleted directory" fx_base 'rm -r dir' 'G reset --hard'
    case_ "reset: hard over an untracked file in the way" fx_base 'git rm -q --cached b.txt; echo mine > b.txt' 'G reset --hard HEAD~1'
    case_ "reset: hard restores the executable bit" fx_base 'chmod -x exec.sh' 'G reset --hard'
    case_ "reset: quiet" fx_base 'echo m >> a.txt' 'G reset -q --hard HEAD~1'
    case_ "reset: -q mixed" fx_base 'echo m >> a.txt' 'G reset -q HEAD~1'
    case_ "reset: path from HEAD" fx_base 'echo m >> a.txt; git add a.txt' 'G reset a.txt'
    case_ "reset: path with --" fx_base 'echo m >> a.txt; git add a.txt' 'G reset -- a.txt'
    case_ "reset: tree-ish and path" fx_base ':' 'G reset HEAD~1 a.txt'
    case_ "reset: tree-ish and path with --" fx_base ':' 'G reset HEAD~1 -- a.txt b.txt'
    case_ "reset: a new file is unstaged" fx_base 'echo n > new.txt; git add new.txt' 'G reset new.txt'
    case_ "reset: a directory" fx_base 'echo m >> dir/c.txt; echo m >> dir/sub/d.txt; git add -A' 'G reset dir'
    case_ "reset: from a subdirectory" fx_base 'echo m >> dir/c.txt; git add -A' 'cd dir; G reset c.txt'
    case_ "reset: soft with paths" fx_base ':' 'G reset --soft HEAD~1 a.txt'
    case_ "reset: hard with paths" fx_base ':' 'G reset --hard HEAD~1 a.txt'
    case_ "reset: unknown revision" fx_base ':' 'G reset nope'
    case_ "reset: unknown revision hard" fx_base ':' 'G reset --hard nope'
    case_ "reset: ambiguous revision and file" fx_base 'echo x > side' 'G reset side'
    case_ "reset: ORIG_HEAD is written" fx_base ':' 'G reset --hard HEAD~1; G reset --hard ORIG_HEAD'
    case_ "reset: detached HEAD" fx_base 'git checkout -q --detach HEAD' 'G reset --hard HEAD~1'
    case_ "reset: branch tip by name" fx_base ':' 'G reset --soft side'
    case_ "reset: from a tag" fx_linear ':' 'G reset --hard v1'
    case_ "reset: unborn HEAD" fx_empty 'git add x.txt' 'G reset'
    case_ "reset: unborn HEAD hard" fx_empty 'git add x.txt' 'G reset --hard'
    case_ "reset: clears a merge" fx_conflict ':' 'G reset --hard'
    case_ "reset: mixed in a conflict" fx_conflict ':' 'G reset'
    case_ "reset: soft in a merge refused" fx_conflict ':' 'G reset --soft HEAD'
    case_ "reset: --keep with a clean tree" fx_base ':' 'G reset --keep HEAD~1'
    case_ "reset: --keep keeps unrelated local changes" fx_base 'echo m >> dir/c.txt' 'G reset --keep HEAD~1'
    case_ "reset: --keep refuses a clash" fx_base 'echo m >> a.txt' 'G reset --keep HEAD~1'
    case_ "reset: spaces and unicode" fx_base 'echo m >> "sp ace.txt"; echo m >> "ünï.txt"; git add -A' 'G reset "sp ace.txt" "ünï.txt"'
    case_ "reset: CRLF" fx_crlf 'printf "x\n" > win.txt; git add win.txt' 'G reset win.txt'
fi

# --- commit -------------------------------------------------------------------------------

if wanted commit; then
    case_ "commit: -m" fx_base 'echo m >> a.txt; git add a.txt' 'G commit -m "change a"'
    case_ "commit: root commit" fx_empty 'git add x.txt' 'G commit -m "root"'
    case_ "commit: two -m make paragraphs" fx_base 'echo m >> a.txt; git add a.txt' 'G commit -m "subject" -m "body text"'
    case_ "commit: -F file" fx_base 'echo m >> a.txt; git add a.txt; printf "from file\n\nbody\n" > /tmp/msg.$$' 'G commit -F /tmp/msg.$$; rm -f /tmp/msg.$$'
    case_ "commit: -F stdin" fx_base 'echo m >> a.txt; git add a.txt' 'echo "from stdin" | G commit -F -'
    case_ "commit: -a" fx_base 'echo m >> a.txt; rm b.txt; echo n > new.txt' 'G commit -a -m "all"'
    case_ "commit: -am" fx_base 'echo m >> a.txt' 'G commit -am "all in one"'
    case_ "commit: nothing to commit" fx_base ':' 'G commit -m x'
    case_ "commit: nothing but untracked" fx_base 'echo n > new.txt' 'G commit -m x'
    case_ "commit: unstaged changes only" fx_base 'echo m >> a.txt' 'G commit -m x'
    case_ "commit: empty repository" fx_empty ':' 'G commit -m x'
    case_ "commit: --allow-empty" fx_base ':' 'G commit --allow-empty -m "empty"'
    case_ "commit: --amend -m" fx_base ':' 'G commit --amend -m "reworded"'
    case_ "commit: --amend --no-edit with staged" fx_base 'echo m >> a.txt; git add a.txt' 'G commit --amend --no-edit'
    case_ "commit: --amend keeps the author" fx_base 'export GIT_AUTHOR_NAME="Other"; git commit -q --allow-empty -m "by other"' 'G commit --amend --no-edit'
    case_ "commit: --amend --reset-author" fx_base 'export GIT_AUTHOR_NAME="Other"; git commit -q --allow-empty -m "by other"; unset GIT_AUTHOR_NAME; export GIT_AUTHOR_NAME="Ada Author"' 'G commit --amend --no-edit --reset-author'
    case_ "commit: --amend of a root commit" fx_empty 'git add x.txt; git commit -qm root' 'G commit --amend -m "new root"'
    case_ "commit: --amend of a merge commit" fx_merge ':' 'G commit --amend -m "merge reworded"'
    case_ "commit: --amend that would be empty" fx_base 'git reset -q --soft HEAD~1; git commit -qm one --allow-empty' 'G commit --amend --no-edit'
    case_ "commit: --amend in an empty repository" fx_empty ':' 'G commit --amend -m x'
    case_ "commit: --author" fx_base 'echo m >> a.txt; git add a.txt' 'G commit -m x --author="Zed Writer <zed@example.com>"'
    case_ "commit: --author invalid" fx_base 'echo m >> a.txt; git add a.txt' 'G commit -m x --author="nobody"'
    case_ "commit: --date" fx_base 'echo m >> a.txt; git add a.txt' 'G commit -m x --date="2020-02-03T04:05:06 +0200"'
    case_ "commit: --date raw" fx_base 'echo m >> a.txt; git add a.txt' 'G commit -m x --date="1500000000 -0700"'
    case_ "commit: --date rfc2822" fx_base 'echo m >> a.txt; git add a.txt' 'G commit -m x --date="Thu, 07 Apr 2005 22:13:13 +0200"'
    case_ "commit: -s" fx_base 'echo m >> a.txt; git add a.txt' 'G commit -s -m "signed"'
    case_ "commit: -s with a body" fx_base 'echo m >> a.txt; git add a.txt' 'G commit -s -m "signed" -m "the body"'
    case_ "commit: -s twice does not repeat" fx_base ':' 'G commit --allow-empty -s -m "signed"; G commit --amend -s --no-edit'
    case_ "commit: -s after other trailers" fx_base 'echo m >> a.txt; git add a.txt' 'G commit -s -m "subject" -m "Bug: 12"'
    case_ "commit: --fixup" fx_base 'echo m >> a.txt; git add a.txt' 'G commit --fixup=HEAD~1'
    case_ "commit: --fixup of a fixup" fx_base 'echo m >> a.txt; git add a.txt; git commit -q --fixup=HEAD~1; echo n >> a.txt' 'G commit -a --fixup=HEAD'
    case_ "commit: --squash -m" fx_base 'echo m >> a.txt; git add a.txt' 'G commit --squash=HEAD~1 -m "note"'
    case_ "commit: -C reuses message and author" fx_base 'echo m >> a.txt; git add a.txt' 'G commit -C HEAD~1'
    case_ "commit: -m empty is refused" fx_base 'echo m >> a.txt; git add a.txt' 'G commit -m ""'
    case_ "commit: --allow-empty-message" fx_base 'echo m >> a.txt; git add a.txt' 'G commit --allow-empty-message -m ""'
    case_ "commit: message whitespace is cleaned" fx_base 'echo m >> a.txt; git add a.txt' 'G commit -m "  subject with trailing   " -m "" -m "body   "'
    case_ "commit: a # line is kept with -m" fx_base 'echo m >> a.txt; git add a.txt' 'G commit -m "subject" -m "# not a comment"'
    case_ "commit: --cleanup=verbatim" fx_base 'echo m >> a.txt; git add a.txt' 'G commit --cleanup=verbatim -m "subject   " -m "x"'
    case_ "commit: with paths" fx_base 'echo m >> a.txt; echo n >> b.txt; git add a.txt' 'G commit -m "only b" b.txt'
    case_ "commit: with a directory" fx_base 'echo m >> dir/c.txt; echo n >> dir/sub/d.txt; echo o >> a.txt' 'G commit -m "dir" dir'
    case_ "commit: with a deleted path" fx_base 'rm b.txt; echo o >> a.txt' 'G commit -m "gone" b.txt'
    case_ "commit: with an unknown path" fx_base 'echo m >> a.txt' 'G commit -m x nope'
    case_ "commit: with an untracked path" fx_base 'echo n > new.txt' 'G commit -m x new.txt'
    case_ "commit: --include with paths" fx_base 'echo m >> a.txt; echo n >> b.txt; git add a.txt' 'G commit -i -m "both" b.txt'
    case_ "commit: -a with paths is refused" fx_base 'echo m >> a.txt' 'G commit -a -m x a.txt'
    case_ "commit: executable file" fx_base 'printf "#!/bin/sh\n" > run.sh; chmod +x run.sh; git add run.sh' 'G commit -m "run"'
    case_ "commit: rename shows in the summary" fx_base 'git mv b.txt b-renamed.txt' 'G commit -m "rename"'
    case_ "commit: delete and mode in the summary" fx_base 'git rm -q a.txt; chmod -x exec.sh; git add exec.sh' 'G commit -m "mixed"'
    case_ "commit: many files" fx_base 'for i in 1 2 3 4 5 6 7 8; do echo $i > f$i.txt; done; git add -A' 'G commit -m "many"'
    case_ "commit: from a subdirectory" fx_base 'echo m >> a.txt; git add a.txt' 'cd dir; G commit -m "from dir"'
    case_ "commit: unmerged paths refuse" fx_conflict ':' 'G commit -m x'
    case_ "commit: concluding a merge" fx_conflict 'printf "resolved\n" > f.txt; git add f.txt' 'G commit -m "merged"'
    case_ "commit: concluding a merge from MERGE_MSG" fx_conflict 'printf "resolved\n" > f.txt; git add f.txt' 'GIT_EDITOR=true G commit'
    case_ "commit: partial commit during a merge" fx_conflict 'printf "resolved\n" > f.txt; git add f.txt' 'G commit -m x f.txt'
    case_ "commit: detached HEAD" fx_base 'git checkout -q --detach HEAD; echo m >> a.txt; git add a.txt' 'G commit -m "detached"'
    case_ "commit: spaces and unicode paths" fx_unicode 'echo m >> "dír ectory/fïle one.txt"; echo n > "新しい.txt"; git add -A' 'G commit -m "unicode"'
    case_ "commit: CRLF content" fx_crlf 'printf "three\r\n" >> win.txt; git add win.txt' 'G commit -m "crlf"'
    case_ "commit: empty file and binary" fx_base ': > empty.txt; printf "\0\1" > bin.dat; git add -A' 'G commit -m "files"'
    case_ "commit: editor supplies the message" fx_base 'echo m >> a.txt; git add a.txt' 'GIT_EDITOR="sh -c '"'"'echo from editor > \"\$1\"'"'"' sh" G commit'
    case_ "commit: editor leaves nothing" fx_base 'echo m >> a.txt; git add a.txt' 'GIT_EDITOR=true G commit'
    case_ "commit: editor failing" fx_base 'echo m >> a.txt; git add a.txt' 'GIT_EDITOR=false G commit'
    case_ "commit: editor with -m and -e" fx_base 'echo m >> a.txt; git add a.txt' 'GIT_EDITOR="sh -c '"'"'printf \"edited: \" | cat - \"\$1\" > \"\$1.n\"; mv \"\$1.n\" \"\$1\"'"'"' sh" G commit -e -m "base"'
    case_ "commit: core.editor" fx_base 'echo m >> a.txt; git add a.txt; git config core.editor "sh -c '"'"'echo via core.editor > \"\$1\"'"'"' sh"' 'G commit'
    case_ "commit: amend through the editor" fx_base ':' 'GIT_EDITOR="sh -c '"'"'echo amended in editor > \"\$1\"'"'"' sh" G commit --amend'
    case_ "commit: commit.template" fx_base 'echo m >> a.txt; git add a.txt; printf "templated subject\n\nfrom the template\n" > /tmp/tpl.$$; git config commit.template /tmp/tpl.$$' 'GIT_EDITOR=true G commit; rm -f /tmp/tpl.$$'
    case_ "commit: template unused with -m" fx_base 'echo m >> a.txt; git add a.txt; printf "templated\n" > /tmp/tpl2.$$; git config commit.template /tmp/tpl2.$$' 'G commit -m "explicit"; rm -f /tmp/tpl2.$$'
    case_ "commit: --no-verify skips hooks" fx_base 'echo m >> a.txt; git add a.txt; printf "#!/bin/sh\nexit 1\n" > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit' 'G commit -n -m "skipped"'
    case_ "commit: pre-commit hook rejects" fx_base 'echo m >> a.txt; git add a.txt; printf "#!/bin/sh\nexit 1\n" > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit' 'G commit -m "rejected"'
    case_ "commit: commit-msg hook rewrites" fx_base 'echo m >> a.txt; git add a.txt; printf "#!/bin/sh\necho \"hooked\" >> \"\$1\"\n" > .git/hooks/commit-msg; chmod +x .git/hooks/commit-msg' 'G commit -m "msg"'
    case_ "commit: commit-msg hook rejects" fx_base 'echo m >> a.txt; git add a.txt; printf "#!/bin/sh\nexit 3\n" > .git/hooks/commit-msg; chmod +x .git/hooks/commit-msg' 'G commit -m "msg"'
    case_ "commit: post-commit hook runs" fx_base 'echo m >> a.txt; git add a.txt; printf "#!/bin/sh\ngit rev-parse HEAD > .git/post-commit-ran\n" > .git/hooks/post-commit; chmod +x .git/hooks/post-commit' 'G commit -m "msg"; cat .git/post-commit-ran'
    case_ "commit: committer different from author shows Author" fx_base 'echo m >> a.txt; git add a.txt; export GIT_COMMITTER_NAME="Someone Else"' 'G commit -m x'
    case_ "commit: reflog of an amend" fx_base ':' 'G commit --amend --no-edit; G commit --amend -m "second"'
    case_ "commit: quiet" fx_base 'echo m >> a.txt; git add a.txt' 'G commit -q -m x'
    case_ "commit: unknown option" fx_base ':' 'G commit --frobnicate'
fi

# --- gerrit ---------------------------------------------------------------------------------

GERRIT_SETUP='if [ "$SIDE" = git ]; then cp "'"$HERE"'/gerrit-commit-msg.sh" .git/hooks/commit-msg; chmod +x .git/hooks/commit-msg; else git config gerrit.createChangeId true; fi'

if wanted gerrit; then
    case_ "gerrit: Change-Id on a plain message" fx_base "$GERRIT_SETUP"'; echo m >> a.txt; git add a.txt' 'G commit -m "Fix the a file"'
    case_ "gerrit: Change-Id with a body" fx_base "$GERRIT_SETUP"'; echo m >> a.txt; git add a.txt' 'G commit -m "Fix the a file" -m "A longer explanation
that runs over two lines."'
    case_ "gerrit: Change-Id goes before Signed-off-by" fx_base "$GERRIT_SETUP"'; echo m >> a.txt; git add a.txt' 'G commit -s -m "Fix the a file"'
    case_ "gerrit: Change-Id after Bug footer" fx_base "$GERRIT_SETUP"'; echo m >> a.txt; git add a.txt' 'G commit -m "Fix" -m "Body." -m "Bug: 1234"'
    case_ "gerrit: Change-Id before another footer" fx_base "$GERRIT_SETUP"'; echo m >> a.txt; git add a.txt' 'G commit -m "Fix" -m "Body." -m "Reviewed-by: Someone <s@example.com>"'
    case_ "gerrit: Change-Id among Bug and Signed-off-by" fx_base "$GERRIT_SETUP"'; echo m >> a.txt; git add a.txt' 'G commit -s -m "Fix" -m "Body." -m "Bug: 1
Test: ran it"'
    case_ "gerrit: existing Change-Id is kept" fx_base "$GERRIT_SETUP"'; echo m >> a.txt; git add a.txt' 'G commit -m "Fix" -m "Change-Id: I0123456789012345678901234567890123456789"'
    case_ "gerrit: fixup is left alone" fx_base "$GERRIT_SETUP"'; echo m >> a.txt; git add a.txt' 'G commit --fixup=HEAD'
    case_ "gerrit: squash is left alone" fx_base "$GERRIT_SETUP"'; echo m >> a.txt; git add a.txt' 'G commit --squash=HEAD -m "n"'
    case_ "gerrit: root commit has no parent" fx_empty "$GERRIT_SETUP"'; git add x.txt' 'G commit -m "Initial"'
    case_ "gerrit: -a" fx_base "$GERRIT_SETUP"'; echo m >> a.txt; echo n >> b.txt' 'G commit -a -m "Both files"'
    case_ "gerrit: author and date given" fx_base "$GERRIT_SETUP"'; echo m >> a.txt; git add a.txt' 'G commit -m "By another" --author="Zed <z@example.com>" --date="1600000000 +0100"'
    case_ "gerrit: amend of a commit without one" fx_base "$GERRIT_SETUP"'' 'G commit --amend -m "Reworded"'
    case_ "gerrit: amend keeps the Change-Id" fx_base "$GERRIT_SETUP"'' 'G commit --allow-empty -m "First"; G commit --amend -m "Second subject"'
    case_ "gerrit: amend --no-edit" fx_base "$GERRIT_SETUP"'' 'G commit --allow-empty -m "One"; G commit --amend --no-edit'
    case_ "gerrit: two commits get different ids" fx_base "$GERRIT_SETUP"'' 'G commit --allow-empty -m "One"; G commit --allow-empty -m "One"'
    case_ "gerrit: editor message with comments" fx_base "$GERRIT_SETUP"'; echo m >> a.txt; git add a.txt' 'GIT_EDITOR="sh -c '"'"'printf \"Edited subject\n\n# a comment\nbody\n\" > \"\$1\"'"'"' sh" G commit'
    case_ "gerrit: message with trailing blank lines" fx_base "$GERRIT_SETUP"'; echo m >> a.txt; git add a.txt; printf "Subject\n\n\n\nBody\n\n\n" > /tmp/gm.$$' 'G commit -F /tmp/gm.$$; rm -f /tmp/gm.$$'
    case_ "gerrit: unicode subject" fx_base "$GERRIT_SETUP"'; echo m >> a.txt; git add a.txt' 'G commit -m "Korrigiere Größe der Überschrift 日本語"'
    case_ "gerrit: URL-like first line is not a footer" fx_base "$GERRIT_SETUP"'; echo m >> a.txt; git add a.txt' 'G commit -m "Subject" -m "https://example.com/page"'
    case_ "gerrit: disabled" fx_base 'git config gerrit.createChangeId false; echo m >> a.txt; git add a.txt' 'G commit -m "no id"'
    case_ "gerrit: --change-id without config" fx_base 'echo m >> a.txt; git add a.txt; if [ "$SIDE" = git ]; then cp "'"$HERE"'/gerrit-commit-msg.sh" .git/hooks/commit-msg; chmod +x .git/hooks/commit-msg; fi' 'if [ "$SIDE" = ours ]; then G commit --change-id -m "Flagged"; else G commit -m "Flagged"; fi'
fi

# --- switch -------------------------------------------------------------------------------

if wanted switch; then
    case_ "switch: to a branch" fx_base ':' 'G switch side'
    case_ "switch: back with -" fx_base ':' 'G switch side; G switch -'
    case_ "switch: -c" fx_base ':' 'G switch -c feature'
    case_ "switch: -c from a start point" fx_base ':' 'G switch -c feature side'
    case_ "switch: -c from a tag" fx_linear ':' 'G switch -c from-tag v1'
    case_ "switch: -c existing" fx_base ':' 'G switch -c side'
    case_ "switch: -C resets" fx_base ':' 'G switch -C side main'
    case_ "switch: -C creates" fx_base ':' 'G switch -C brandnew HEAD~1'
    case_ "switch: -C the current branch" fx_base ':' 'G switch -C main HEAD~1'
    case_ "switch: --detach" fx_base ':' 'G switch --detach HEAD~1'
    case_ "switch: --detach a tag" fx_linear ':' 'G switch --detach v1'
    case_ "switch: -d no argument" fx_base ':' 'G switch -d'
    case_ "switch: unknown branch" fx_base ':' 'G switch nope'
    case_ "switch: a tag needs --detach" fx_linear ':' 'G switch v1'
    case_ "switch: a commit needs --detach" fx_base ':' 'G switch HEAD~1'
    case_ "switch: already on it" fx_base ':' 'G switch main'
    case_ "switch: dirty tree carries over when files agree" fx_base 'echo m >> dir/c.txt' 'G switch side'
    case_ "switch: dirty tree refused" fx_base 'echo m >> a.txt' 'G switch side'
    case_ "switch: staged change refused" fx_base 'echo m >> a.txt; git add a.txt' 'G switch side'
    case_ "switch: staged change that matches the target is kept" fx_base 'git show side:a.txt > a.txt; git add a.txt' 'G switch side'
    case_ "switch: -f discards changes" fx_base 'echo m >> a.txt; echo n > new.txt; git add new.txt' 'G switch -f side'
    case_ "switch: --discard-changes" fx_base 'echo m >> a.txt' 'G switch --discard-changes side'
    case_ "switch: untracked file in the way" fx_base 'git switch -q side; git rm -q b.txt; git commit -qm rmb; git switch -q main; echo mine > b.txt; rm b.txt' 'G switch side; echo mine > b.txt; G switch main'
    case_ "switch: an untracked file would be overwritten" fx_base 'git switch -q side; echo newfile > only-side.txt; git add only-side.txt; git commit -qm add; git switch -q main; echo mine > only-side.txt' 'G switch side'
    case_ "switch: file removed by the target" fx_base 'git switch -q side; git rm -q a.txt; git commit -qm rma; git switch -q main' 'G switch side'
    case_ "switch: directory removed by the target" fx_base 'git switch -q side; git rm -rq dir; git commit -qm rmdir; git switch -q main' 'G switch side; G switch main'
    case_ "switch: mode change comes along" fx_base 'git switch -q side; chmod +x a.txt; git add a.txt; git commit -qm mode; git switch -q main' 'G switch side'
    case_ "switch: file becomes directory" fx_base 'git switch -q side; git rm -q b.txt; mkdir b.txt; echo x > b.txt/x; git add b.txt; git commit -qm fd; git switch -q main' 'G switch side; G switch main'
    case_ "switch: unmerged paths refuse" fx_conflict 'git branch other2 other' 'G switch other2'
    case_ "switch: in a subdirectory" fx_base ':' 'cd dir; G switch side; G switch -'
    case_ "switch: from a detached HEAD" fx_base 'git checkout -q --detach HEAD~1' 'G switch main'
    case_ "switch: detached to detached" fx_base 'git checkout -q --detach HEAD~1' 'G switch --detach main'
    case_ "switch: unborn branch -c" fx_empty ':' 'G switch -c other'
    case_ "switch: remote branch is guessed" fx_base 'git update-ref refs/remotes/origin/feature HEAD~1; git remote add origin /nowhere' 'G switch feature'
    case_ "switch: remote branch with -c --track" fx_base 'git update-ref refs/remotes/origin/feature HEAD~1; git remote add origin /nowhere' 'G switch -c mine --track origin/feature'
    case_ "switch: -c from a remote branch tracks it" fx_base 'git update-ref refs/remotes/origin/feature HEAD~1; git remote add origin /nowhere' 'G switch -c mine origin/feature'
    case_ "switch: report of the upstream" fx_base 'git update-ref refs/remotes/origin/main HEAD~1; git remote add origin /nowhere; git branch -u origin/main main' 'G switch side; G switch main'
    case_ "switch: spaces and unicode" fx_base 'git switch -q side; echo m > "ünï.txt"; git add -A; git commit -qm uni; git switch -q main' 'G switch side'
    case_ "switch: invalid new name" fx_base ':' 'G switch -c "bad..name"'
    case_ "switch: quiet" fx_base ':' 'G switch -q side'
    case_ "switch: reflog of switch -" fx_base ':' 'G switch side; G switch main; G switch -; G switch -'
    case_ "switch: CRLF files survive" fx_crlf 'git switch -q -c other; printf "z\r\n" > win.txt; git commit -qam crlf2; git switch -q main' 'G switch other; G switch main'
    case_ "switch: no argument" fx_base ':' 'G switch'
fi

# --- checkout -----------------------------------------------------------------------------

if wanted checkout; then
    case_ "checkout: a branch" fx_base ':' 'G checkout side'
    case_ "checkout: back with -" fx_base ':' 'G checkout side; G checkout -'
    case_ "checkout: -b" fx_base ':' 'G checkout -b feature'
    case_ "checkout: -b from a start point" fx_base ':' 'G checkout -b feature side'
    case_ "checkout: -b existing" fx_base ':' 'G checkout -b side'
    case_ "checkout: -B resets" fx_base ':' 'G checkout -B side main'
    case_ "checkout: -B the current branch" fx_base ':' 'G checkout -B main HEAD~1'
    case_ "checkout: a tag detaches" fx_linear ':' 'G checkout v1'
    case_ "checkout: a commit detaches" fx_base ':' 'G checkout HEAD~1'
    case_ "checkout: --detach" fx_base ':' 'G checkout --detach'
    case_ "checkout: --detach a branch" fx_base ':' 'G checkout --detach side'
    case_ "checkout: from detached to a branch" fx_base 'git checkout -q --detach HEAD~1' 'G checkout main'
    case_ "checkout: unknown name" fx_base ':' 'G checkout nope'
    case_ "checkout: dirty refused" fx_base 'echo m >> a.txt' 'G checkout side'
    case_ "checkout: dirty unrelated file is carried" fx_base 'echo m >> dir/c.txt' 'G checkout side'
    case_ "checkout: -f" fx_base 'echo m >> a.txt' 'G checkout -f side'
    case_ "checkout: file from the index" fx_base 'echo m >> a.txt' 'G checkout a.txt'
    case_ "checkout: file with --" fx_base 'echo m >> a.txt' 'G checkout -- a.txt'
    case_ "checkout: file from a branch" fx_base ':' 'G checkout side -- a.txt'
    case_ "checkout: file from a commit without --" fx_base ':' 'G checkout HEAD~1 a.txt'
    case_ "checkout: file from a commit updates the index" fx_base ':' 'G checkout HEAD~1 -- a.txt b.txt'
    case_ "checkout: directory from a branch" fx_base 'echo m >> dir/c.txt' 'G checkout side -- dir'
    case_ "checkout: dot" fx_base 'echo m >> a.txt; rm b.txt' 'G checkout .'
    case_ "checkout: dot from a branch" fx_base ':' 'G checkout side .'
    case_ "checkout: deleted file" fx_base 'rm b.txt' 'G checkout -- b.txt'
    case_ "checkout: a path that does not exist" fx_base ':' 'G checkout -- nope'
    case_ "checkout: a path from a rev that does not have it" fx_base ':' 'G checkout side -- nope'
    case_ "checkout: ambiguous name" fx_base 'echo x > side' 'G checkout side'
    case_ "checkout: disambiguated with --" fx_base 'echo x > side; echo y >> side' 'G checkout -- side; G checkout side --'
    case_ "checkout: --ours" fx_conflict ':' 'G checkout --ours f.txt'
    case_ "checkout: --theirs" fx_conflict ':' 'G checkout --theirs f.txt'
    case_ "checkout: unmerged path" fx_conflict ':' 'G checkout -- f.txt'
    case_ "checkout: unmerged tree refuses a switch" fx_conflict 'git branch other2 other' 'G checkout other2'
    case_ "checkout: remote branch is guessed" fx_base 'git update-ref refs/remotes/origin/feature HEAD~1; git remote add origin /nowhere' 'G checkout feature'
    case_ "checkout: -b from a remote branch tracks it" fx_base 'git update-ref refs/remotes/origin/feature HEAD~1; git remote add origin /nowhere' 'G checkout -b mine origin/feature'
    case_ "checkout: --track" fx_base 'git update-ref refs/remotes/origin/feature HEAD~1; git remote add origin /nowhere' 'G checkout --track origin/feature'
    case_ "checkout: executable bit from a branch" fx_base 'git switch -q side; chmod -x exec.sh; git add exec.sh; git commit -qm x; git switch -q main' 'G checkout side -- exec.sh'
    case_ "checkout: from a subdirectory" fx_base 'echo m >> dir/c.txt; echo m >> a.txt' 'cd dir; G checkout c.txt ../a.txt'
    case_ "checkout: spaces and unicode" fx_base 'echo m >> "sp ace.txt"; rm "ünï.txt"' 'G checkout -- "sp ace.txt" "ünï.txt"'
    case_ "checkout: empty repository -b" fx_empty ':' 'G checkout -b other'
    case_ "checkout: quiet" fx_base ':' 'G checkout -q side'
    case_ "checkout: HEAD" fx_base 'echo m >> a.txt' 'G checkout HEAD'
    case_ "checkout: HEAD with a path" fx_base 'echo m >> a.txt; git add a.txt' 'G checkout HEAD a.txt'
    case_ "checkout: -b on a dirty tree keeps changes" fx_base 'echo m >> a.txt' 'G checkout -b other'
fi

# --- branch -------------------------------------------------------------------------------

if wanted branch; then
    case_ "branch: list" fx_base 'git branch zeta; git branch alpha' 'G branch'
    case_ "branch: list with -v" fx_base 'git branch zeta' 'G branch -v'
    case_ "branch: list with -vv and upstreams" fx_base 'git update-ref refs/remotes/origin/main HEAD~1; git remote add origin /nowhere; git branch -u origin/main main; git branch side2 side' 'G branch -vv'
    case_ "branch: -vv gone upstream" fx_base 'git config branch.side.remote origin; git config branch.side.merge refs/heads/gone; git remote add origin /nowhere' 'G branch -vv'
    case_ "branch: -a" fx_base 'git update-ref refs/remotes/origin/main HEAD; git update-ref refs/remotes/origin/feature side; git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main' 'G branch -a; G branch -r'
    case_ "branch: -avv" fx_base 'git update-ref refs/remotes/origin/main HEAD; git update-ref refs/remotes/origin/feature side; git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main' 'G branch -avv'
    case_ "branch: --list pattern" fx_base 'git branch topic-1; git branch topic-2' 'G branch --list "topic-*"; G branch -l "s*"'
    case_ "branch: --show-current" fx_base ':' 'G branch --show-current'
    case_ "branch: --show-current detached" fx_base 'git checkout -q --detach' 'G branch --show-current'
    case_ "branch: list while detached" fx_base 'git checkout -q --detach HEAD~1' 'G branch; G branch -v'
    case_ "branch: list while detached on a tag" fx_linear 'git checkout -q v1' 'G branch'
    case_ "branch: unborn" fx_empty ':' 'G branch; G branch -v'
    case_ "branch: create" fx_base ':' 'G branch feature'
    case_ "branch: create at a commit" fx_base ':' 'G branch feature HEAD~1'
    case_ "branch: create at a tag" fx_linear ':' 'G branch feature v1'
    case_ "branch: create existing" fx_base ':' 'G branch side'
    case_ "branch: create with -f" fx_base ':' 'G branch -f side main'
    case_ "branch: create with -f on the current" fx_base ':' 'G branch -f main HEAD~1'
    case_ "branch: bad start point" fx_base ':' 'G branch feature nope'
    case_ "branch: bad name" fx_base ':' 'G branch "bad..name"; G branch -x; G branch "has space"'
    case_ "branch: from a remote tracks it" fx_base 'git update-ref refs/remotes/origin/feature HEAD~1; git remote add origin /nowhere' 'G branch mine origin/feature'
    case_ "branch: --track from a local branch" fx_base ':' 'G branch --track mine side'
    case_ "branch: --no-track from a remote" fx_base 'git update-ref refs/remotes/origin/feature HEAD~1; git remote add origin /nowhere' 'G branch --no-track mine origin/feature'
    case_ "branch: unborn create" fx_empty ':' 'G branch feature'
    case_ "branch: delete" fx_base 'git branch topic HEAD' 'G branch -d topic'
    case_ "branch: delete not merged" fx_base 'git switch -q -c work; echo w > w.txt; git add w.txt; git commit -qm w; git switch -q main' 'G branch -d work'
    case_ "branch: -D not merged" fx_base 'git switch -q -c work; echo w > w.txt; git add w.txt; git commit -qm w; git switch -q main' 'G branch -D work'
    case_ "branch: delete several" fx_base 'git branch a1; git branch a2' 'G branch -d a1 a2 nope'
    case_ "branch: delete the current" fx_base ':' 'G branch -d main; G branch -D main'
    case_ "branch: delete unknown" fx_base ':' 'G branch -d nope'
    case_ "branch: delete drops the tracking config" fx_base 'git update-ref refs/remotes/origin/main HEAD; git remote add origin /nowhere; git branch -t topic origin/main' 'G branch -D topic'
    case_ "branch: delete a remote-tracking branch" fx_base 'git update-ref refs/remotes/origin/old HEAD' 'G branch -d -r origin/old'
    case_ "branch: delete a nested branch removes the directory" fx_base 'git branch feature/x/y' 'G branch -d feature/x/y'
    case_ "branch: list nested branches" fx_base 'git branch feature/x/y; git branch feature/z' 'G branch'
    case_ "branch: rename the current" fx_base ':' 'G branch -m trunk'
    case_ "branch: rename another" fx_base ':' 'G branch -m side other'
    case_ "branch: rename to existing" fx_base ':' 'G branch -m side main'
    case_ "branch: -M to existing" fx_base 'git branch other' 'G branch -M side other'
    case_ "branch: rename unknown" fx_base ':' 'G branch -m nope x'
    case_ "branch: rename keeps upstream config" fx_base 'git update-ref refs/remotes/origin/main HEAD; git remote add origin /nowhere; git branch -u origin/main side' 'G branch -m side moved'
    case_ "branch: rename the current keeps its log" fx_base 'git commit -q --allow-empty -m e1; git commit -q --allow-empty -m e2' 'G branch -m renamed'
    case_ "branch: rename unborn" fx_empty ':' 'G branch -m trunk'
    case_ "branch: copy" fx_base ':' 'G branch -c side copy'
    case_ "branch: copy the current" fx_base ':' 'G branch -c copy'
    case_ "branch: -u" fx_base 'git update-ref refs/remotes/origin/main HEAD; git remote add origin /nowhere' 'G branch -u origin/main'
    case_ "branch: --set-upstream-to a branch" fx_base 'git update-ref refs/remotes/origin/main HEAD; git remote add origin /nowhere' 'G branch --set-upstream-to=origin/main side'
    case_ "branch: -u a local branch" fx_base ':' 'G branch -u main side'
    case_ "branch: -u unknown upstream" fx_base ':' 'G branch -u nope'
    case_ "branch: --unset-upstream" fx_base 'git update-ref refs/remotes/origin/main HEAD; git remote add origin /nowhere; git branch -u origin/main main' 'G branch --unset-upstream'
    case_ "branch: --unset-upstream without one" fx_base ':' 'G branch --unset-upstream'
    case_ "branch: --contains" fx_base 'git branch late; git checkout -q late; git commit -q --allow-empty -m late; git checkout -q main' 'G branch --contains HEAD~1; G branch --contains late'
    case_ "branch: --merged" fx_base 'git branch late; git checkout -q late; git commit -q --allow-empty -m late; git checkout -q main' 'G branch --merged; G branch --no-merged; G branch --merged late'
    case_ "branch: --sort=-refname" fx_base 'git branch zeta; git branch alpha' 'G branch --sort=-refname'
    case_ "branch: --format" fx_base 'git branch zeta' 'G branch --format="%(refname:short) %(objectname:short)"'
    case_ "branch: --points-at" fx_base ':' 'G branch --points-at HEAD~1'
    case_ "branch: -q create" fx_base ':' 'G branch -q feature'
    case_ "branch: long names align in -v" fx_base 'git branch a-rather-long-branch-name-for-alignment' 'G branch -v'
    case_ "branch: multi-line subject in -v" fx_base 'git commit -q --allow-empty -m "first line" -m "second paragraph"' 'G branch -v'
fi

# --- tag ----------------------------------------------------------------------------------

if wanted tag; then
    case_ "tag: lightweight" fx_base ':' 'G tag v1'
    case_ "tag: at a commit" fx_base ':' 'G tag v0 HEAD~1'
    case_ "tag: annotated with -a -m" fx_base ':' 'G tag -a -m "release one" v1'
    case_ "tag: -m implies -a" fx_base ':' 'G tag -m "release one" v1'
    case_ "tag: annotated at a commit" fx_base ':' 'G tag -a -m "old" v0 HEAD~1'
    case_ "tag: multi-paragraph message" fx_base ':' 'G tag -a -m "subject" -m "body" v1'
    case_ "tag: message from a file" fx_base 'printf "from a file\n\nmore\n" > /tmp/tm.$$' 'G tag -a -F /tmp/tm.$$ v1; rm -f /tmp/tm.$$'
    case_ "tag: message whitespace" fx_base ':' 'G tag -a -m "  spaced   " v1'
    case_ "tag: empty message" fx_base ':' 'G tag -a -m "" v1'
    case_ "tag: annotated through the editor" fx_base ':' 'GIT_EDITOR="sh -c '"'"'echo from editor > \"\$1\"'"'"' sh" G tag -a v1'
    case_ "tag: editor leaves nothing" fx_base ':' 'GIT_EDITOR=true G tag -a v1'
    case_ "tag: existing" fx_base 'git tag v1' 'G tag v1'
    case_ "tag: -f moves" fx_base 'git tag v1 HEAD~1' 'G tag -f v1'
    case_ "tag: -f to the same place" fx_base 'git tag v1' 'G tag -f v1'
    case_ "tag: -f annotated over lightweight" fx_base 'git tag v1' 'G tag -f -a -m "now annotated" v1'
    case_ "tag: bad name" fx_base ':' 'G tag "bad..name"; G tag "-x"; G tag "has space"'
    case_ "tag: bad object" fx_base ':' 'G tag v1 nope'
    case_ "tag: delete" fx_base 'git tag v1; git tag -a -m x v2' 'G tag -d v1 v2'
    case_ "tag: delete missing" fx_base 'git tag v1' 'G tag -d nope v1'
    case_ "tag: list" fx_base 'git tag v1; git tag v10; git tag v2; git tag -a -m x rel' 'G tag; G tag -l'
    case_ "tag: list with a pattern" fx_base 'git tag v1; git tag v10; git tag w1' 'G tag -l "v*"; G tag --list "w?"'
    case_ "tag: list with -n" fx_base 'git tag v1; git tag -a -m "annotated tag" v2; git tag -a -m "first line" -m "second" v3' 'G tag -n; G tag -n1 -l; G tag -n3 -l v3'
    case_ "tag: --sort=-refname" fx_base 'git tag v1; git tag v10; git tag v2' 'G tag --sort=-refname'
    case_ "tag: --sort=version:refname" fx_base 'git tag v1; git tag v10; git tag v2; git tag v9' 'G tag --sort=version:refname; G tag --sort=-version:refname'
    case_ "tag: --contains" fx_base 'git tag old HEAD~1; git tag new HEAD' 'G tag --contains HEAD; G tag --contains HEAD~1'
    case_ "tag: --no-contains" fx_base 'git tag old HEAD~1; git tag new HEAD' 'G tag --no-contains HEAD'
    case_ "tag: --points-at" fx_base 'git tag old HEAD~1; git tag new HEAD; git tag -a -m x ann HEAD' 'G tag --points-at HEAD'
    case_ "tag: --merged" fx_base 'git tag old HEAD~1; git tag new HEAD' 'G tag --merged HEAD~1'
    case_ "tag: --format" fx_base 'git tag v1; git tag -a -m x v2' 'G tag --format="%(refname:short) %(objecttype)"'
    case_ "tag: tag of a tag" fx_base 'git tag -a -m inner inner' 'G tag -a -m outer outer inner'
    case_ "tag: of a tree" fx_base ':' 'G tag treetag HEAD^{tree}; G tag -a -m x treeann HEAD^{tree}'
    case_ "tag: list in an empty repository" fx_empty ':' 'G tag'
    case_ "tag: create in an empty repository" fx_empty ':' 'G tag v1'
    case_ "tag: nested name" fx_base ':' 'G tag rel/1.0; G tag rel/2.0; G tag -l "rel/*"; G tag -d rel/1.0'
    case_ "tag: list is sorted bytewise" fx_base 'git tag B; git tag a; git tag _x; git tag Z' 'G tag'
fi


# --- patch ----------------------------------------------------------------------------------

# the prompts and the hunk navigation of git 2.55 (j/k roll over, p/P): older
# gits ask differently, so this group is only compared against 2.55 or later
git_at_least() { [ "$(printf '%s\n%s\n' "$1" "$(git version | awk '{print $3}')" | sort -V | head -n 1)" = "$1" ]; }

if wanted patch && ! git_at_least 2.55; then
    echo "compare_write: patch group skipped: git $(git version | awk '{print $3}') is older than 2.55"
fi

if wanted patch && git_at_least 2.55; then
    case_ "patch: add -p all yes" fx_hunks ':' 'printf "y\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\n" | G add -p'
    case_ "patch: add -p all no" fx_hunks ':' 'printf "n\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\n" | G add -p'
    case_ "patch: add -p a" fx_hunks ':' 'printf "a\na\na\na\na\na\n" | G add -p'
    case_ "patch: add -p d" fx_hunks ':' 'printf "d\nd\nd\nd\nd\nd\n" | G add -p'
    case_ "patch: add -p q" fx_hunks ':' 'printf "y\nq\n" | G add -p'
    case_ "patch: add -p one path" fx_hunks ':' 'printf "y\nn\ny\n" | G add -p f.txt'
    case_ "patch: add -p a directory" fx_hunks ':' 'printf "y\n" | G add -p sub'
    case_ "patch: add -p no changes" fx_hunks 'git checkout -q -- . 2>/dev/null; git reset -q --hard' 'printf "y\n" | G add -p'
    case_ "patch: add -p empty input" fx_hunks ':' 'G add -p </dev/null'
    case_ "patch: add -p split" fx_hunks ':' 'printf "s\ny\nn\ny\n" | G add -p s.c'
    case_ "patch: add -p split and navigation" fx_hunks ':' 'printf "s\nj\nJ\nk\nK\ny\nn\ny\nn\n" | G add -p s.c'
    case_ "patch: add -p help" fx_hunks ':' 'printf "?\nn\nn\nn\n" | G add -p f.txt'
    case_ "patch: add -p unknown and long answers" fx_hunks ':' 'printf "x\nzz\n\ny\ny\ny\n" | G add -p f.txt'
    case_ "patch: add -p cannot split" fx_hunks ':' 'printf "s\ny\ny\ny\n" | G add -p g.txt'
    case_ "patch: add -p previous decisions" fx_hunks ':' 'printf "y\ny\nK\nn\nk\nJ\nd\n" | G add -p f.txt'
    case_ "patch: add -p goto" fx_hunks ':' 'printf "g\n2\ny\ng\n9\ng\nx\nq\n" | G add -p f.txt'
    case_ "patch: add -p search" fx_hunks ':' 'printf "/line 28\ny\n/nomatch\nq\n" | G add -p f.txt'
    case_ "patch: add -p after -p again" fx_hunks 'printf "y\n" | git add -p g.txt >/dev/null' 'printf "y\ny\ny\ny\ny\ny\ny\n" | G add -p'
    case_ "patch: add -p then commit" fx_hunks ':' 'printf "y\nn\ny\ny\n" | G add -p f.txt; G commit -qm picked; G show --stat HEAD; G status --short'
    case_ "patch: reset -p all yes" fx_hunks 'git add -A' 'printf "y\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\n" | G reset -p'
    case_ "patch: reset -p mixed" fx_hunks 'git add -A' 'printf "n\ny\nn\ny\ny\nn\n" | G reset -p'
    case_ "patch: reset -p path" fx_hunks 'git add -A' 'printf "y\nn\n" | G reset -p f.txt'
    case_ "patch: reset -p HEAD" fx_hunks 'git add -A' 'printf "y\ny\n" | G reset -p HEAD -- g.txt'
    case_ "patch: reset -p new file" fx_hunks 'echo new > added.txt; git add -A' 'printf "y\n" | G reset -p added.txt'
    case_ "patch: reset -p tree" fx_hunks ':' 'printf "y\ny\n" | G reset -p other -- g.txt'
    case_ "patch: reset -p nothing staged" fx_hunks ':' 'printf "y\n" | G reset -p'
    case_ "patch: restore -p" fx_hunks ':' 'printf "y\nn\ny\ny\ny\ny\ny\ny\n" | G restore -p'
    case_ "patch: restore -p path" fx_hunks ':' 'printf "n\ny\n" | G restore -p f.txt'
    case_ "patch: restore -p all yes" fx_hunks ':' 'printf "y\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\n" | G restore -p'
    case_ "patch: restore -p split" fx_hunks ':' 'printf "s\ny\nn\ny\n" | G restore -p s.c'
    case_ "patch: restore -p deleted file" fx_hunks ':' 'printf "y\n" | G restore -p del.txt'
    case_ "patch: restore -p staged" fx_hunks 'git add g.txt' 'printf "y\ny\n" | G restore -p -S g.txt'
    case_ "patch: restore -p -S -W" fx_hunks 'git add -A' 'printf "y\ny\ny\ny\ny\ny\ny\ny\n" | G restore -p -S -W'
    case_ "patch: restore -p source" fx_hunks ':' 'printf "y\n" | G restore -p -s other -W g.txt'
    case_ "patch: restore -p source HEAD" fx_hunks ':' 'printf "y\nn\n" | G restore -p --source=HEAD f.txt'
    case_ "patch: checkout -p" fx_hunks ':' 'printf "y\nn\ny\ny\ny\n" | G checkout -p'
    case_ "patch: checkout -p path" fx_hunks ':' 'printf "y\ny\ny\ny\n" | G checkout -p -- f.txt'
    case_ "patch: checkout -p HEAD" fx_hunks 'git add -A' 'printf "y\ny\ny\ny\ny\ny\ny\ny\n" | G checkout -p HEAD'
    case_ "patch: checkout -p tree" fx_hunks 'git add -A; git commit -qm more' 'printf "y\n" | G checkout -p other -- g.txt'
    case_ "patch: add -p mode change and content" fx_hunks 'chmod +x g.txt' 'printf "y\ny\n" | G add -p g.txt'
    case_ "patch: add -p mode change only" fx_hunks ':' 'printf "y\n" | G add -p run.sh'
    case_ "patch: add -p deletion" fx_hunks ':' 'printf "y\n" | G add -p del.txt'
    case_ "patch: add -p no final newline" fx_hunks ':' 'printf "y\n" | G add -p noeol.txt'
    case_ "patch: add -p from a subdirectory" fx_hunks ':' 'cd sub; printf "y\n" | G add -p; printf "y\n" | G add -p ../g.txt'
    case_ "patch: add -p link" fx_links 'ln -sfn elsewhere link' 'printf "y\n" | G add -p'
    case_ "patch: add -p type change" fx_links 'rm link; echo f > link' 'printf "y\ny\ny\n" | G add -p'
    case_ "patch: add -p link replaced by file, no" fx_links 'rm link; echo f > link' 'printf "n\ny\n" | G add -p'
    case_ "patch: reset -p split" fx_hunks 'git add -A' 'printf "s\ny\nn\ny\n" | G reset -p s.c'
    case_ "patch: restore -p mode change" fx_hunks ':' 'printf "y\n" | G restore -p run.sh'
    case_ "patch: restore -p -S -s tree" fx_hunks ':' 'printf "y\ny\n" | G restore -p -S -s other g.txt'
    case_ "patch: add -p quit in the second file" fx_hunks ':' 'printf "y\ny\ny\nq\n" | G add -p'
    case_ "patch: add -p partially staged file" fx_hunks 'printf "y\nn\nn\n" | git add -p f.txt >/dev/null' 'printf "n\ny\n" | G add -p f.txt'
    case_ "patch: add -p twice the same hunk list" fx_hunks ':' 'printf "n\ny\n" | G add -p f.txt; printf "y\n" | G add -p f.txt; G status --short'
    case_ "patch: checkout -p discards then status" fx_hunks ':' 'printf "n\ny\ny\n" | G checkout -p f.txt; G diff --stat'
    case_ "patch: add -p CRLF" fx_crlf 'printf "one\r\nTWO\r\n" > win.txt; printf "mixed\r\nline\nextra\n" > mix.txt' 'printf "y\ny\n" | G add -p'
    case_ "patch: add -p unicode names" fx_unicode 'echo more >> "日本語.txt"; echo more >> "dír ectory/fïle one.txt"' 'printf "y\ny\n" | G add -p'
fi

# --- misc ---------------------------------------------------------------------------------

if wanted misc; then
    case_ "links: switch rewrites a link" fx_links ':' 'G switch other; G switch main'
    case_ "links: status after switching" fx_links ':' 'G switch other'
    case_ "links: rm a link" fx_links ':' 'G rm link dangling'
    case_ "links: rm --cached a link" fx_links ':' 'G rm --cached link'
    case_ "links: mv a link" fx_links ':' 'G mv link renamed-link'
    case_ "links: mv a dangling link" fx_links ':' 'G mv dangling moved'
    case_ "links: restore a deleted link" fx_links 'rm link' 'G restore link'
    case_ "links: checkout a link from another branch" fx_links ':' 'G checkout other -- link'
    case_ "links: reset --hard rewrites links" fx_links 'rm link; ln -s elsewhere link' 'G reset --hard'
    case_ "links: add of an unchanged link is a no-op" fx_links ':' 'G add link; G add -A; G add -u'
    case_ "links: commit -a with a deleted link" fx_links 'rm link' 'G commit -a -m "no link"'
    case_ "links: add of a deleted link" fx_links 'rm dangling' 'G add dangling'
    case_ "links: delete the work tree link and add -A" fx_links 'rm sub/up' 'G add -A'
    case_ "links: add a retargeted link" fx_links 'ln -sfn sub/up link' 'G add link; G status -s; G diff --cached'
    case_ "links: add -A takes a retargeted link" fx_links 'ln -sfn elsewhere link; ln -sfn other dangling' 'G add -A; G diff --cached --raw'
    case_ "links: add -u takes a retargeted link" fx_links 'ln -sfn elsewhere link' 'G add -u; G status --porcelain'
    case_ "links: add a new link" fx_links 'ln -s real.txt fresh; ln -s nowhere fresh2; ln -s sub fresh3' 'G add fresh fresh2 fresh3; G diff --cached'
    case_ "links: add a new link to a directory" fx_links 'ln -s sub subl' 'G add -A; G diff --cached --raw'
    case_ "links: add a file replacing a link" fx_links 'rm link; echo now a file > link' 'G add link; G diff --cached --summary'
    case_ "links: add a link replacing a file" fx_links 'rm real.txt; ln -s link real.txt' 'G add real.txt; G diff --cached --summary'
    case_ "links: commit -a takes a retargeted link" fx_links 'ln -sfn elsewhere link' 'G commit -a -m retarget; G show --stat HEAD; G show HEAD'
    case_ "links: commit -a takes a type change" fx_links 'rm real.txt; ln -s link real.txt; rm link; echo f > link' 'G commit -a -m types; G show --raw HEAD'
    case_ "links: rm refuses a retargeted link" fx_links 'ln -sfn elsewhere link' 'G rm link; G rm -f link; G status -s'
    case_ "links: rm refuses a link edited in the index" fx_links 'ln -sfn elsewhere link; git add link; ln -sfn third link' 'G rm link; G rm --cached link'
    case_ "links: rm of a link replaced by a file" fx_links 'rm link; echo f > link' 'G rm link; G rm -f link'
    case_ "links: restore a retargeted link" fx_links 'ln -sfn elsewhere link' 'G restore link; G status -s'
    case_ "links: restore a link replaced by a file" fx_links 'rm link; echo f > link' 'G restore link; G status -s'
    case_ "links: restore a file replaced by a link" fx_links 'rm real.txt; ln -s link real.txt' 'G restore real.txt; G status -s'
    case_ "links: restore --staged a link" fx_links 'ln -sfn elsewhere link; git add link' 'G restore --staged link; G status -s'
    case_ "links: restore --source other" fx_links ':' 'G restore --source other link; G status -s'
    case_ "links: reset a link path" fx_links 'ln -sfn elsewhere link; git add link' 'G reset link; G status -s'
    case_ "links: reset --hard over retargeted and replaced" fx_links 'ln -sfn elsewhere link; rm real.txt; ln -s link real.txt; ln -sfn dd dangling' 'G reset --hard; G status -s'
    case_ "links: reset --hard other" fx_links 'ln -sfn elsewhere link' 'G reset --hard other; G status -s'
    case_ "links: switch refuses a retargeted link" fx_links 'ln -sfn elsewhere link' 'G switch other; G status -s'
    case_ "links: switch keeps an untouched retarget" fx_links 'ln -sfn elsewhere dangling' 'G switch other; G status -s'
    case_ "links: switch -f over a retargeted link" fx_links 'ln -sfn elsewhere link' 'G switch -f other; G status -s'
    case_ "links: checkout creates links" fx_links 'git switch -q other; git rm -q --cached link; rm -r sub link' 'G checkout main -- .; G status -s'
    case_ "links: checkout a link over a file" fx_links 'rm link; echo f > link; git add link; git commit -qm f' 'G checkout other -- link; G status -s'
    case_ "links: checkout a branch with links over files" fx_links 'git switch -q other; rm link; echo f > link; git add link; git commit -qm f' 'G checkout main; G status -s'
    case_ "links: checkout a branch whose link replaces a directory" fx_links 'git switch -q other; git rm -q -r sub; ln -s real.txt sub; git add sub; git commit -qm d' 'G checkout main; G checkout other; G status -s'
    case_ "links: diff and status of retargets" fx_links 'ln -sfn elsewhere link; rm dangling; echo f > dangling' 'G status -s; G diff; G diff --stat; G diff --raw'
    case_ "links: stash-free: show of a link commit" fx_links ':' 'G show other; G show other --stat; G diff main other'
    case_ "pick: commit uses the picked author" fx_pick 'printf "resolved\n" > f.txt; git add f.txt' 'G commit -m "picked"'
    case_ "pick: commit message from MERGE_MSG" fx_pick 'printf "resolved\n" > f.txt; git add f.txt' 'GIT_EDITOR=true G commit'
    case_ "pick: partial commit refused" fx_pick 'printf "resolved\n" > f.txt; git add f.txt' 'G commit -m x f.txt'
    case_ "pick: switch refused" fx_pick 'printf "resolved\n" > f.txt; git add f.txt' 'G switch other'
    case_ "pick: reset --hard clears the state" fx_pick ':' 'G reset --hard'
    case_ "pick: commit during an unresolved pick" fx_pick ':' 'G commit -m x'
    case_ "state: rebase directory refuses a switch" fx_base 'mkdir -p .git/rebase-merge' 'G switch side'
    case_ "umask 077 files are written private" fx_base 'echo m >> a.txt' 'umask 077; G switch -f side; G reset --hard main'
    case_ "worktree-only files are not touched by switch" fx_base 'echo u > untracked.txt; echo i > ignored.log; echo "*.log" > .git/info/exclude' 'G switch side; G switch main'
    case_ "ignored file in the way is replaced" fx_base 'git switch -q side; echo n > ign.dat; git add -f ign.dat; git commit -qm ign; git switch -q main; echo "*.dat" > .git/info/exclude; echo mine > ign.dat' 'G switch side'
    case_ "empty directory in the way is replaced" fx_base 'git switch -q side; echo n > newdir; git add newdir; git commit -qm nd; git switch -q main; mkdir newdir' 'G switch side'
    case_ "commit -a keeps untracked out" fx_base 'echo n > untracked.txt; echo m >> a.txt' 'G commit -am "tracked only"'
    case_ "branch -d after a merge commit" fx_merge ':' 'G branch -d feat'
    case_ "commit with a long subject" fx_base 'echo m >> a.txt; git add a.txt' 'G commit -m "a very long subject line that goes on and on and on and on and on and on and on and on and on and on"'
    case_ "commit message with CR LF" fx_base 'echo m >> a.txt; git add a.txt' 'G commit -m "$(printf "crlf subject\r\n\r\nbody\r\n")"'
fi


# --- core.ignorecase -----------------------------------------------------------------------
# Two kinds of volume run these cases (see the notes at the top of the script):
#   - the work directory itself. On macOS that is a real case-insensitive APFS
#     volume. On Linux it is case-sensitive: `core.ignorecase=true` makes git
#     (and 1git) compare names against the index the way they do on a folding
#     volume, and a hard link stands in for the same file under another case.
#   - on Linux, a tmpfs mounted `casefold` in a user namespace (when the kernel
#     and `unshare` allow it): a real folding volume, where lstat of the other
#     spelling succeeds and readdir lists one name. Cases whose fixture says
#     `mkdir DIR` or `ln a.txt A.txt` mean "the same directory/file" there.
# No case is skipped on either; a Linux without the namespace runs only the
# first kind, and says so by not printing the "casefold tmpfs" line.

fx_case() {
    fx_base "$1"
    mkdir -p Docs
    printf 'rd\n' > Docs/Readme.md
    printf 'mk\n' > Makefile
    g add -A
    commit_at "case names"
}

IC='git config core.ignorecase true'
# `mv a.txt A.txt` of a case-only rename as every volume does it: rename(2)
# onto a name that folds to the source is a no-op on some kernels (tmpfs
# casefold keeps the old spelling), APFS spells it anew; two steps give both.
mvc() { mv "$1" "$1.mvc.tmp" && mv "$1.mvc.tmp" "$2"; }
fx_dir() { rm -rf "$1"; mkdir -p "$1"; }
if wanted icase; then
    case_ "icase: status after a case-only rename" fx_case "$IC; mvc a.txt A.txt" 'G status -s; G status --porcelain=v2 -b'
    case_ "icase: untracked case variant of a tracked file" fx_case "$IC; echo n > B.TXT" 'G status -s; G status --porcelain=v2 -b'
    case_ "icase: untracked case variant of a tracked directory" fx_case "$IC; mkdir DIR; echo n > DIR/new.txt" 'G status -s -uall; G status -s'
    case_ "icase: untracked variant, nested" fx_case "$IC; mkdir -p docs; echo n > docs/README.MD; echo m > docs/new.md" 'G status -s -uall'
    case_ "icase: add a case variant of a tracked file" fx_case "$IC; echo n > B.TXT" 'G add B.TXT; G status -s; git ls-files -s'
    case_ "icase: add after a case-only rename" fx_case "$IC; mvc a.txt A.txt" 'G add A.txt; G status -s; git ls-files'
    case_ "icase: add -A after a case-only rename" fx_case "$IC; mvc a.txt A.txt" 'G add -A; G status -s; git ls-files'
    case_ "icase: add . after a case-only rename" fx_case "$IC; mvc a.txt A.txt" 'G add .; G status -s; git ls-files'
    case_ "icase: add a new file in a case variant directory" fx_case "$IC; mkdir DIR; echo n > DIR/new.txt" 'G add DIR/new.txt; git ls-files'
    case_ "icase: add changed file by variant name" fx_case "$IC; echo m >> a.txt" 'G add A.TXT; G status -s'
    case_ "icase: add -u after rename" fx_case "$IC; mvc a.txt A.txt" 'G add -u; G status -s; git ls-files'
    case_ "icase: rm by variant name" fx_case "$IC" 'G rm A.TXT; G status -s'
    case_ "icase: rm --cached by variant name" fx_case "$IC" 'G rm --cached B.txt; G status -s'
    case_ "icase: rm -r by variant directory" fx_case "$IC" 'G rm -r DIR; G status -s'
    case_ "icase: mv to a case-only name" fx_case "$IC" 'G mv a.txt A.txt; G status -s; git ls-files'
    case_ "icase: mv by variant name" fx_case "$IC" 'G mv B.TXT bb.txt; G status -s'
    case_ "icase: mv onto a case variant" fx_case "$IC" 'G mv a.txt B.TXT; G status -s'
    case_ "icase: mv -f onto a case variant" fx_case "$IC" 'G mv -f a.txt B.TXT; G status -s'
    case_ "icase: mv directory to a case-only name" fx_case "$IC" 'G mv dir Dir; G status -s; git ls-files'
    case_ "icase: restore by variant name" fx_case "$IC; echo m >> a.txt" 'G restore A.TXT; G status -s'
    case_ "icase: restore --staged by variant name" fx_case "$IC; echo m >> a.txt; git add a.txt" 'G restore --staged A.TXT; G status -s'
    case_ "icase: checkout -- by variant name" fx_case "$IC; echo m >> a.txt" 'G checkout -- A.TXT; G status -s'
    case_ "icase: reset by variant name" fx_case "$IC; echo m >> a.txt; git add a.txt" 'G reset A.TXT; G status -s'
    case_ "icase: diff by variant name" fx_case "$IC; echo m >> a.txt" 'G diff A.TXT; G diff --stat DIR'
    case_ "icase: commit by variant name" fx_case "$IC; echo m >> a.txt" 'G commit -m x A.TXT; G status -s'
    case_ "icase: switch over a case variant untracked" fx_case "$IC; git switch -q side; echo n > Zed.txt; git add Zed.txt; git commit -qm z; git switch -q main; echo mine > zed.txt" 'G switch side; G status -s'
    case_ "icase: switch where branch has case variant of a tracked file" fx_case "$IC; git switch -q side; git rm -q --cached a.txt; mv a.txt A.txt; git add A.txt; git commit -qm case; git switch -q main" 'G switch side; G status -s; git ls-files'
    case_ "icase: switch back after case rename" fx_case "$IC; git switch -q side; git mv a.txt A.txt; git commit -qm case; git switch -q main" 'G switch side; git ls-files; G switch main; git ls-files; G status -s'
    case_ "icase: reset --hard over a case rename" fx_case "$IC; git mv a.txt A.txt; git commit -qm case" 'G reset --hard HEAD~1; git ls-files; G status -s'
    case_ "icase: clean does not delete case variants of tracked files" fx_case "$IC; echo n > B.TXT; echo m > new.txt" 'G clean -n; G clean -f; G status -s'
    # A hard link stands in for the same file under another case, which is what
    # a case-insensitive volume answers (same size, same mtime, same inode).
    FXR="$IC; git switch -q side; git mv a.txt A.txt; git commit -qm case; git switch -q main"
    case_ "icase: switch onto a case-only rename, the new name already there" fx_case "$FXR; ln a.txt A.txt" 'G switch side; G status -s; git ls-files'
    case_ "icase: switch onto a case-only rename, different content there" fx_case "$FXR; echo mine > A.txt" 'G switch side; G status -s; git ls-files'
    case_ "icase: switch back over the case-only rename" fx_case "$FXR; git switch -q side; ln a.txt a.txt.x; rm a.txt.x" 'G switch main; G status -s; git ls-files'
    case_ "icase: reset --hard onto a case-only rename" fx_case "$FXR; ln a.txt A.txt" 'G reset --hard side; G status -s; git ls-files'
    case_ "icase: merge a case-only rename" fx_case "$FXR; ln a.txt A.txt" 'G merge side; G status -s; git ls-files'
    case_ "icase: merge a case-only rename, different content there" fx_case "$FXR; echo mine > A.txt" 'G merge side; G status -s; git ls-files'
    case_ "icase: merge a case-only rename over an edit" fx_case "$FXR; echo more >> a.txt; git commit -qam edit" 'G merge side; G status -s; git ls-files'
    case_ "icase: cherry-pick a case-only rename" fx_case "$FXR; ln a.txt A.txt" 'G cherry-pick side; G status -s; git ls-files'
    case_ "icase: rebase over a case-only rename" fx_case "$FXR; echo more >> b.txt; git commit -qam edit; git switch -q side" 'G rebase main; G status -s; git ls-files'
    case_ "icase: checkout a branch with a case-only rename" fx_case "$FXR; ln a.txt A.txt" 'G checkout side; G status -s; git ls-files'
    case_ "icase: checkout a path from a case-only rename" fx_case "$FXR" 'G checkout side -- A.txt; G status -s; git ls-files'
    case_ "icase: restore a path from a case-only rename" fx_case "$FXR" 'G restore --source=side --staged --worktree A.txt; G status -s; git ls-files'
    case_ "icase: stash apply over a case-only rename" fx_case "$IC; echo m >> a.txt; git stash -q; git mv a.txt A.txt; git commit -qm case" 'G stash pop; G status -s; git ls-files'
    case_ "icase: untracked directory spelled differently" fx_case "$IC; mkdir -p Dir/sub; echo n > Dir/sub/new.txt; echo m > Dir/c.txt" 'G status -s; G status -s -uall; G add -A; G status -s; git ls-files'
    case_ "icase: add --dry-run -v with a variant directory" fx_case "$IC; mkdir -p Dir; echo n > Dir/new.txt" 'G add -n -v Dir/new.txt; G add -v Dir/new.txt; git ls-files'
    case_ "icase: add -f with a variant name" fx_case "$IC; echo n > B.TXT" 'G add -f B.TXT; G status -s; git ls-files'
    case_ "icase: commit -a with a case-only rename" fx_case "$IC; mvc a.txt A.txt" 'G commit -am x; git ls-files; G status -s'
    case_ "icase: rm a case-only renamed file" fx_case "$IC; mvc a.txt A.txt" 'G rm a.txt; G status -s'
    case_ "icase: mv an untracked variant" fx_case "$IC; echo n > B.TXT" 'G mv B.TXT c.txt; G status -s'
    case_ "icase: ignored file shadows nothing" fx_case "$IC; echo '*.log' > .gitignore; echo n > X.LOG; echo n > a.LOG" 'G status -s --ignored; G add .; G status -s'
    case_ "icase: mv onto the same file under another case" fx_case "$IC; ln a.txt A.txt" 'G mv a.txt A.txt; G status -s; git ls-files'
    case_ "icase: mv a file to its own name" fx_case "$IC" 'G mv a.txt a.txt; G status -s'
    case_ "icase: mv into a case variant of a directory" fx_case "$IC" 'G mv a.txt DIR/a.txt; G status -s; git ls-files'
    case_ "icase: switch over a case-only directory rename" fx_case "$IC; git switch -q side; git mv dir Dir; git commit -qm dir; git switch -q main" 'G switch side; G status -s; git ls-files; G switch main; G status -s; git ls-files'
    case_ "icase: untracked file in a variant directory is added under the index spelling" fx_case "$IC; mkdir -p DOCS; echo n > DOCS/New.md" 'G add DOCS/New.md; G status -s; git ls-files'
    case_ "icase: add with a variant directory and a variant file" fx_case "$IC; mkdir -p DOCS; echo changed > DOCS/README.MD" 'G add DOCS/README.MD; G status -s; git ls-files'
    # `init` probes the volume by asking whether `.git/CoNfIg` exists: on a
    # case-insensitive volume it is the `config` just written. Creating the
    # stray file first makes a case-sensitive one answer the same way.
    case_ "icase: init on a volume where CoNfIg is config" fx_dir ':' 'mkdir -p .git; : > .git/CoNfIg; G init -q .; cat .git/config >> "$log"'
    case_ "icase: init --bare on such a volume" fx_dir ':' 'mkdir -p r.git; : > r.git/CoNfIg; G init -q --bare r.git; rm -rf r.git/hooks r.git/info r.git/description; cat r.git/config >> "$log"'
    case_ "icase: init sha256 on such a volume" fx_dir ':' 'mkdir -p .git; : > .git/CoNfIg; G init -q --object-format=sha256 .; cat .git/config >> "$log"'
    case_ "icase: init on a case-sensitive volume" fx_dir ':' 'G init -q .; cat .git/config >> "$log"'
    case_ "icase: init sha256 on a case-sensitive volume" fx_dir ':' 'G init -q --object-format=sha256 .; cat .git/config >> "$log"'
    # the same through `-c` on the command line, without the repository's config
    case_ "icase: -c core.ignorecase on status" fx_case "echo n > B.TXT; mkdir DIR; echo n > DIR/new.txt" 'G -c core.ignorecase=true status -s -uall; G status -s -uall'
    case_ "icase: -c core.ignorecase on add -A" fx_case "mvc a.txt A.txt; echo n > B.TXT; mkdir DIR; echo n > DIR/new.txt" 'G -c core.ignorecase=true add -A; G status -s; git ls-files'
    case_ "icase: -c core.ignorecase on clean" fx_case "echo n > B.TXT; echo z > zzz.txt" 'G -c core.ignorecase=true clean -n; G clean -n'
    case_ "icase: -c core.ignorecase on mv" fx_case "ln a.txt A.txt" 'G -c core.ignorecase=true mv a.txt A.txt; G status -s'
fi

[ -f "$HERE/compare_write_more.sh" ] && . "$HERE/compare_write_more.sh"

echo "compare_write: $n cases, $bad differing"
[ $bad -eq 0 ]
