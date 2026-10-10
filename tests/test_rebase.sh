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
    export GIT_AUTHOR_DATE='1700000000 +0000' GIT_COMMITTER_DATE='1700000000 +0000' GIT_EDITOR=${RB_ED:-true}
    export GIT_SEQUENCE_EDITOR="sh $WORK/rb_seded.sh" T_SCRATCH="$WORK"
}

rb_git() { ( rb_env; git "$@" ); }
rb_ours() { ( rb_env; "$WORK/t_rebase" "$1/.git" "$1" "${@:2}" ); }

cat >"$WORK/rb_seded.sh" <<'SH'
#!/bin/sh
[ -n "$SEDSCRIPT" ] && sed -i.bak -e "$SEDSCRIPT" "$1" && rm -f "$1.bak"
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
                git-rebase-todo*|done) grep -v '^#' "$r/.git/rebase-merge/$f" | grep -v '^$' | sed 's/^\([a-z]* [0-9a-f]\{40,64\}\) # /\1 /' ;;
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


cat >"$WORK/rb_ed.sh" <<'SH'
#!/bin/sh
{ printf 'edited line\n\n'; cat "$1"; } >"$1.new" && mv "$1.new" "$1"
SH

# rb_do <g|o> <repo> <args...>: the operation done by git or by us
rb_do() {
    local who=$1 r=$2; shift 2
    if [ "$who" = g ]; then
        if [ "$1" = start ]; then shift; rb_git -C "$r" rebase "$@"; else rb_git -C "$r" rebase "--$1" "${@:2}"; fi
    else
        rb_ours "$r" "$@"
    fi
}

rb_resolve() {
    printf 'a\nb\nRES\nd\ne\nf\ng\nH\n' >"$1/f"; rb_git -C "$1" add f
}
rb_stage_extra() {
    echo extra >"$1/x"; rb_git -C "$1" add x
}
rb_edit_file() {
    echo changed >"$1/k"
}
rb_nothing() { :; }
rb_dirty_k() { echo dirty >"$1/k"; }
rb_dirty_f() { printf 'a\nb\nDIRTY\nd\ne\nf\ng\nh\n' >"$1/f"; }
rb_untracked() { echo u >"$1/untracked"; }

# rb_flow <label> <branch> <start args> <mid fn> <ops...>: start by A, mid, ops by B; all four A/B pairings equal git/git
rb_flow() {
    local label=$1 branch=$2 args=$3 mid=$4; shift 4
    rb_only "$label" || return 0
    local pair ref="" got A B op bad_pair=""
    for pair in gg go og oo; do
        A=${pair:0:1}; B=${pair:1:1}
        local r=$WORK/rb_f$pair
        rb_twin "$WORK/rb_src" "$r"
        rb_git -C "$r" checkout -q "$branch"
        ${RB_PRE:-:} "$r"
        rb_do $A "$r" start $args >/dev/null 2>&1
        $mid "$r"
        for op in "$@"; do
            case $op in
                resolve) rb_resolve "$r" ;;
                stage) rb_stage_extra "$r" ;;
                dirty) rb_edit_file "$r" ;;
                *) rb_do $B "$r" $op >"$WORK/rb_f.out" 2>&1 ;;
            esac
        done
        got=$(rb_state "$r")
        if [ "$pair" = gg ]; then ref=$got; elif [ "$got" != "$ref" ]; then
            bad "rebase: $label: $A starts, $B finishes: differs from git" "$(diff <(echo "$ref") <(echo "$got") | head -${RB_DIFF:-20})"
            bad_pair=1
        fi
        rb_fsck "$r" "$label $pair" || bad_pair=1
    done
    [ -z "$bad_pair" ] && note "rebase: $label (git/ours start and finish in all four pairings, states equal)"
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

        RB_ED="sh $WORK/rb_ed.sh" SEDSCRIPT='s/^pick \(.*\) t2$/reword \1 t2/' rb_compare "reword with a changed message" topic "-i main"
        RB_ED="sh $WORK/rb_ed.sh" SEDSCRIPT='s/^pick \(.*\) t3$/squash \1 t3/;s/^pick \(.*\) t2$/squash \1 t2/' rb_compare "squash chain, message edited" topic "-i main"
        RB_ED="sh $WORK/rb_ed.sh" SEDSCRIPT='s/^pick \(.*\) t2$/squash \1 t2/' rb_compare "squash, message edited" topic "-i main"
        RB_ED="sh $WORK/rb_ed.sh" rb_compare "autosquash, message edited" fix "-i --autosquash main"
        rb_compare "autostash, dirty tracked file" topic "--autostash main" rb_dirty_k
        rb_compare "autostash, untracked file is left alone" topic "--autostash main" rb_untracked
        rb_compare "autostash, clean tree" topic "--autostash main"
        rb_compare "autostash, interactive" topic "-i --autostash main" rb_dirty_k
        rb_compare "autostash whose pop conflicts" topic "--autostash main" rb_dirty_f
        rb_compare "autostash with a conflicting pick" conf "--autostash main" rb_dirty_k
        rb_compare "dirty tree without autostash is refused" topic "main" rb_dirty_k
        RB_PRE=rb_dirty_k rb_flow "autostash, conflict, resolve, continue" conf "--autostash main" rb_resolve continue
        RB_PRE=rb_dirty_k rb_flow "autostash, conflict, abort" conf "--autostash main" rb_nothing abort
        RB_PRE=rb_dirty_k rb_flow "autostash, conflict, quit stores the stash" conf "--autostash main" rb_nothing quit
        SEDSCRIPT='s/^pick \(.*\) t2$/edit \1 t2/' RB_PRE=rb_dirty_k rb_flow "autostash, edit, continue" topic "-i --autostash main" rb_nothing continue
        rb_flow "conflict, resolve, continue" conf "main" rb_resolve continue
        rb_flow "conflict, resolve, continue, interactive" conf "-i main" rb_resolve continue
        rb_flow "conflict, skip" conf "main" rb_nothing skip
        rb_flow "conflict, abort" conf "main" rb_nothing abort
        rb_flow "conflict, quit" conf "main" rb_nothing quit
        rb_flow "conflict, abort after resolving" conf "main" rb_resolve abort
        rb_flow "conflict, continue with no resolution is refused" conf "main" rb_nothing continue
        SEDSCRIPT='s/^pick \(.*\) t2$/edit \1 t2/' rb_flow "edit, continue" topic "-i main" rb_nothing continue
        SEDSCRIPT='s/^pick \(.*\) t2$/edit \1 t2/' rb_flow "edit, stage a file, continue amends" topic "-i main" rb_stage_extra continue
        SEDSCRIPT='s/^pick \(.*\) t2$/edit \1 t2/' rb_flow "edit, abort" topic "-i main" rb_nothing abort
        SEDSCRIPT='s/^pick \(.*\) t2$/edit \1 t2/' rb_flow "edit, skip" topic "-i main" rb_nothing skip
        SEDSCRIPT='2s/^/break\n/' rb_flow "break, continue" topic "-i main" rb_nothing continue
        SEDSCRIPT='2s/^/exec echo hi; false\n/' rb_flow "failed exec, continue" topic "-i main" rb_nothing continue
        SEDSCRIPT='2s/^/exec echo hi; false\n/' rb_flow "failed exec, abort" topic "-i main" rb_nothing abort
        SEDSCRIPT='s/^pick \(.*\) c3$/squash \1 c3/' rb_flow "squash conflict, resolve, continue" conf "-i main" rb_resolve continue
        SEDSCRIPT='s/^pick \(.*\) c3$/squash \1 c3/' rb_flow "squash conflict, skip" conf "-i main" rb_nothing skip
        rb_flow "empty stop, continue" redund "-i main" rb_nothing continue
        rb_flow "empty stop, skip" redund "-i main" rb_nothing skip
        RB_PRE=rb_dirty_k rb_flow "dirty tree refuses a start" topic "main" rb_nothing abort

        cat >"$WORK/rb_set.sh" <<'SH'
#!/bin/sh
printf 'new subject\n\nnew body\n' >"$1"
SH
        rb_decl() {
            local r=$WORK/rb_decl_$1 g=$WORK/rb_decl_g
            rb_twin "$WORK/rb_src" "$g"; rb_twin "$WORK/rb_src" "$r"
            rb_git -C "$g" checkout -q topic; rb_git -C "$r" checkout -q topic
            if [ "$4" = two ]; then
                ( export RB_ED=false SEDSCRIPT="$2"; rb_env; git -C "$g" rebase -i main ) >/dev/null 2>&1
                ( export RB_ED="sh $WORK/rb_set.sh"; rb_env; git -C "$g" rebase --continue ) >/dev/null 2>&1
            else
                ( export RB_ED="sh $WORK/rb_set.sh" SEDSCRIPT="$2"; rb_env; git -C "$g" rebase -i main ) >/dev/null 2>&1
            fi
            ( export SEDSCRIPT="$2" DECLINE=1; rb_ours "$r" start -i main ) >"$WORK/rb_decl.out" 2>&1
            rb_ours "$r" continue -m $'new subject\n\nnew body\n' >>"$WORK/rb_decl.out" 2>&1
            if [ "$(rb_state "$g")" != "$(rb_state "$r")" ]; then
                bad "rebase: $3: state differs from git" "$(diff <(rb_state "$g") <(rb_state "$r") | head -20)" "$(head -3 "$WORK/rb_decl.out")"
            else
                rb_fsck "$r" "$3" && note "rebase: $3 (the caller supplies the message; state equals git's with the same message)"
            fi
        }
        rb_only "no editor" && {
            rb_decl reword 's/^pick \(.*\) t2$/reword \1 t2/' "no editor: reword stops, continue -m" one
            rb_decl squash 's/^pick \(.*\) t2$/squash \1 t2/' "no editor: squash stops, continue -m" two
        }
    }
fi

# The rebase screens under a real pty (`pty_rebase.py`): the menu, the todo editor, the
# conflict flow, abort, skip, quit, the banner, reword and squash through $EDITOR, autostash,
# a pull that rebases, and git/UI interop both ways, each compared with `git rebase`.
# It builds its own fixtures under `$WORK/pty_rebase`.
if rb_only "pty"; then
    if [ -f "$WORK/gitui" ] || bash scripts/build-gitui.sh -o "$WORK/gitui_rebase" >"$WORK/gitui_rebase_build.log" 2>&1; then
        [ -f "$WORK/gitui" ] && rb_bin="$WORK/gitui" || rb_bin="$WORK/gitui_rebase"
        if command -v python3 >/dev/null; then
            if rb_out=$(python3 tests/pty_rebase.py "$rb_bin" "$WORK/pty_rebase" 2>&1); then
                note "rebase pty: $(echo "$rb_out" | grep -c '^ok') rebase-screen checks passed under a real pty"
            else
                bad "rebase pty" "$rb_out"
            fi
        else
            echo "rebase pty: skipped, no python3" >&2
        fi
    else
        bad "rebase pty: scripts/build-gitui.sh" "$(cat "$WORK/gitui_rebase_build.log")"
    fi
fi
