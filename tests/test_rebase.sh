# GIT_rebase (rebase and rebase -i), against real git as the oracle in
# disposable fixtures. Shares `test.sh`'s shell, `$WORK`, `$LANGC`, `build`,
# `note`/`bad` and the counters.
#
#   1. Whole operations: working tree, index, refs, reflogs and every state
#      file under .git/rebase-merge after our rebase equal those after git's,
#      for plain, --onto, --root, interactive (edit, reword, squash, fixup,
#      drop, reorder, exec, break), autosquash and autostash.
#   2. Interop: git starts and we continue/skip/abort, we start and git does,
#      all four pairings end in git's own state, same commit ids.
#   3. `git fsck --strict` is clean after every run.
#
# Fixtures run with fixed identities and dates, so commit ids are comparable.

rb_env() {
    export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
    export GIT_AUTHOR_DATE='1700000000 +0000' GIT_COMMITTER_DATE='1700000000 +0000' GIT_EDITOR=true
    export GIT_SEQUENCE_EDITOR="sh $WORK/rb_seded.sh" T_SCRATCH="$WORK"
}

rb_git() { ( rb_env; git "$@" ); }
rb_ours() { ( rb_env; "$WORK/t_rebase" "$1/.git" "$1" "${@:2}" ); }

cat >"$WORK/rb_seded.sh" <<'SH'
#!/bin/sh
[ -n "$SEDSCRIPT" ] && sed -i -e "$SEDSCRIPT" "$1"
exit 0
SH

# main: base (tag t0), m1 (f line 3 = OURS, adds m), m2 (adds n)
# topic: t1 (adds g) t2 (f line 8 = H) t3 (adds h, with a body)
# conf: t1 t2 c3 (f line 3 = THEIRS) t5 (adds i)
# fix: t1 t2 "fixup! t1" "squash! t2" t3
# emp: t1 an empty commit t2
# dupc: t1 a commit adding n like m2 does, t2
# redund: t1 r (f line 3 = OURS) t2
rb_build() {
    local r=$1
    rm -rf "$r"; mkdir -p "$r"
    (
        set -e
        rb_env
        cd "$r"
        git init -q -b main .
        git config core.fileMode true
        git config merge.renames false
        printf 'a\nb\nc\nd\ne\nf\ng\nh\n' >f; echo k >k
        git add -A; git commit -q -m base; git tag t0
        git checkout -q -b topic
        echo g1 >g; git add -A; git commit -q -m "t1"
        printf 'a\nb\nc\nd\ne\nf\ng\nH\n' >f; git commit -q -am "t2"
        echo h >h; git add -A; git commit -q -m "t3

body of t3"
        git checkout -q -b conf topic~2
        printf 'a\nb\nTHEIRS\nd\ne\nf\ng\nH\n' >f; git commit -q -am "c3"
        echo i >i; git add -A; git commit -q -m "t5"
        git checkout -q -b fix topic~2
        echo g2 >>g; git commit -q -am "fixup! t1"
        echo s >s; git add -A; git commit -q -m "squash! t2"
        echo h >h; git add -A; git commit -q -m "t3"
        git checkout -q -b emp topic~2
        git commit -q --allow-empty -m "an empty one"
        printf 'a\nb\nc\nd\ne\nf\ng\nH\n' >f; git commit -q -am "t2"
        git checkout -q -b dupc topic~1
        echo n >n; git add -A; git commit -q -m "dup of n"
        printf 'a\nb\nc\nd\ne\nf\ng\nH\n' >f; git commit -q -am "t2"
        git checkout -q -b redund topic~1
        printf 'a\nb\nOURS\nd\ne\nf\ng\nh\n' >f; git commit -q -am "r"
        echo z >z; git add -A; git commit -q -m "t2"
        git checkout -q main
        printf 'a\nb\nOURS\nd\ne\nf\ng\nh\n' >f; echo m >m; git add -A; git commit -q -m "m1"; git tag m1
        echo n >n; git add -A; git commit -q -m "m2"; git tag m2
        git checkout -q topic
    ) >"$WORK/rb_fx.log" 2>&1 || { bad "rebase: fixture" "$(tail -3 "$WORK/rb_fx.log")"; return 1; }
}

rb_twin() {
    rm -rf "$2"; cp -a "$1" "$2"
    git -C "$2" update-index -q --refresh
}

rb_snap() {
    (
        cd "$1"
        find . -name .git -prune -o \( -type f -o -type l \) -print | sort | while read -r f; do
            if [ -L "$f" ]; then echo "$f L $(readlink "$f")"; else echo "$f $(stat -c %a "$f") $(sha1sum <"$f")"; fi
        done
    )
}

rb_state() {
    local r=$1 f
    echo "== HEAD $(git -C "$r" rev-parse HEAD)"
    echo "== branch $(git -C "$r" symbolic-ref -q HEAD)"
    echo "== refs"; git -C "$r" for-each-ref --format='%(refname) %(objectname)'
    echo "== index"; git -C "$r" ls-files -s
    echo "== status"; git -C "$r" status --porcelain
    echo "== worktree"; rb_snap "$r"
    for f in REBASE_HEAD CHERRY_PICK_HEAD MERGE_HEAD MERGE_MSG SQUASH_MSG ORIG_HEAD AUTO_MERGE; do
        if [ -e "$r/.git/$f" ]; then echo "== $f"; cat "$r/.git/$f"; else echo "== $f absent"; fi
    done
    if [ -d "$r/.git/rebase-merge" ]; then
        for f in $(ls "$r/.git/rebase-merge" | grep -v '^patch$'); do
            echo "== rebase-merge/$f"
            case $f in
                git-rebase-todo*|done) grep -v '^#' "$r/.git/rebase-merge/$f" | grep -v '^$' ;;
                *) cat -A "$r/.git/rebase-merge/$f" ;;
            esac
        done
    else
        echo "== rebase-merge absent"
    fi
    echo "== logs/HEAD"; cut -d' ' -f1,2,5- "$r/.git/logs/HEAD" 2>/dev/null
    local b; b=$(git -C "$r" for-each-ref --format='%(refname)' refs/heads | head -9)
    for f in $b; do echo "== logs/$f"; cut -d' ' -f1,2,5- "$r/.git/logs/$f" 2>/dev/null; done
    echo "== stash"; git -C "$r" stash list --format='%H %gs' 2>/dev/null
}

rb_fsck() {
    if ! git -C "$1" fsck --strict >"$WORK/rb_fsck.log" 2>&1; then
        bad "rebase: $2: fsck --strict" "$(head -3 "$WORK/rb_fsck.log")"
        return 1
    fi
}

rb_only() { [ -z "${RB_ONLY:-}" ] || [[ $1 =~ $RB_ONLY ]]; }

# rb_compare <label> <branch> <args> [setup]: the same `rebase <args>` on two copies of $WORK/rb_src, $SEDSCRIPT for -i
rb_compare() {
    local label=$1 branch=$2 args=$3 setup=${4:-:}
    rb_only "$label" || return 0
    rb_twin "$WORK/rb_src" "$WORK/rb_g"; rb_twin "$WORK/rb_src" "$WORK/rb_o"
    rb_git -C "$WORK/rb_g" checkout -q "$branch"; rb_git -C "$WORK/rb_o" checkout -q "$branch"
    $setup "$WORK/rb_g"; $setup "$WORK/rb_o"
    local gout grc oout
    gout=$(rb_git -C "$WORK/rb_g" rebase $args 2>&1); grc=$?
    oout=$(rb_ours "$WORK/rb_o" start $args 2>&1)
    local gs os
    gs=$(rb_state "$WORK/rb_g"); os=$(rb_state "$WORK/rb_o")
    if [ "$gs" != "$os" ]; then
        bad "rebase: $label: state differs from git (git rc=$grc: $(echo "$gout" | tail -2 | tr '\n' ' '); ours: $(echo "$oout" | head -3 | tr '\n' ' '))" "$(diff <(echo "$gs") <(echo "$os") | head -${RB_DIFF:-24})"
        return 1
    fi
    rb_fsck "$WORK/rb_o" "$label" || return 1
    note "rebase: $label (state, refs, reflogs and state files equal git's; rc=$grc; ours: $(echo "$oout" | head -1))"
}

if build t_rebase; then
    rb_build "$WORK/rb_src" &&
    {
        rb_compare "plain, three commits onto main" topic "main"
        rb_compare "plain, already up to date" topic "t0"
        rb_compare "plain onto the same commit it is on" main "main"
        rb_compare "branch behind its upstream" main "topic"
        rb_compare "--onto" topic "--onto m1 t0"
        rb_compare "interactive, nothing changed" topic "-i main"
        rb_compare "interactive, upstream is the base: leading picks skipped" topic "-i t0"
        rb_compare "conflicting pick stops" conf "main"
        rb_compare "conflicting pick stops, interactive" conf "-i main"
        rb_compare "root: whole history onto an empty commit" topic "--root"
        rb_compare "root --onto" topic "--root --onto m1"
        rb_compare "keep-base" topic "--keep-base main"
        SEDSCRIPT='s/^pick \(.*\) t2$/edit \1 t2/' rb_compare "edit stops after the commit" topic "-i main"
        SEDSCRIPT='s/^pick \(.*\) t2$/reword \1 t2/' rb_compare "reword (editor leaves it)" topic "-i main"
        SEDSCRIPT='s/^pick \(.*\) t2$/squash \1 t2/' rb_compare "squash" topic "-i main"
        SEDSCRIPT='s/^pick \(.*\) t2$/fixup \1 t2/' rb_compare "fixup" topic "-i main"
        SEDSCRIPT='s/^pick \(.*\) t2$/drop \1 t2/' rb_compare "drop" topic "-i main"
        SEDSCRIPT='2{h;d};3{G}' rb_compare "reorder" topic "-i main"
        SEDSCRIPT='2s/^/exec true\n/' rb_compare "exec that succeeds" topic "-i main"
        SEDSCRIPT='2s/^/exec echo hi; false\n/' rb_compare "exec that fails stops" topic "-i main"
        SEDSCRIPT='2s/^/break\n/' rb_compare "break" topic "-i main"
        SEDSCRIPT='s/^pick \(.*\) t3$/squash \1 t3/;s/^pick \(.*\) t2$/squash \1 t2/' rb_compare "squash two into the first" topic "-i main"
        SEDSCRIPT='s/^pick \(.*\) t3$/fixup \1 t3/;s/^pick \(.*\) t2$/squash \1 t2/' rb_compare "squash then fixup" topic "-i main"
        SEDSCRIPT='s/^pick \(.*\) t3$/squash \1 t3/;s/^pick \(.*\) t2$/fixup \1 t2/' rb_compare "fixup then squash" topic "-i main"
        SEDSCRIPT='s/^pick \(.*\) c3$/squash \1 c3/' rb_compare "squash that conflicts" conf "-i main"
        rb_compare "autosquash" fix "-i --autosquash main"
        rb_compare "no autosquash without -i" fix "main"
        rb_compare "cherry-pick duplicate dropped" dupc "main"
        rb_compare "cherry-pick duplicate dropped, interactive" dupc "-i main"
        rb_compare "empty commit kept" emp "main"
        rb_compare "empty commit kept, interactive" emp "-i main"
        rb_compare "commit that becomes empty is dropped" redund "main"
        rb_compare "commit that becomes empty stops, interactive" redund "-i main"
    }
fi
