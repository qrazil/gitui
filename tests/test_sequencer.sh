# GIT_sequencer (cherry-pick and revert), against real git as the oracle in
# disposable fixtures. Shares `test.sh`'s shell, `$WORK`, `$LANGC`, `build`,
# `note`/`bad` and the counters.
#
#   1. Whole operations: working tree, index, refs, reflogs and every state
#      file (CHERRY_PICK_HEAD, REVERT_HEAD, MERGE_MSG, AUTO_MERGE, ORIG_HEAD,
#      .git/sequencer/*) after our pick or revert equal those after git's, for
#      single commits, ranges, -n, -x, -m, empty and redundant picks.
#   2. Interop: git starts and we continue/skip/abort, we start and git does,
#      all four pairings end in git's own state, same commit ids.
#   3. Refusals leave nothing written; `git fsck --strict` is clean.

sq_env() {
    export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
    export GIT_AUTHOR_DATE='1700000000 +0000' GIT_COMMITTER_DATE='1700000000 +0000' GIT_EDITOR=true
}

sq_git() { ( sq_env; git "$@" ); }
sq_ours() { ( sq_env; "$WORK/t_sequencer" "$1/.git" "$1" "${@:2}" ); }

# main (checked out): base, M1 (f line 3 = OURS, adds m), M2 (f line 3 = OURS2, adds n), M3 (adds p)
# side: s1 adds g, s2 edits f line 8, s3 edits f line 3 (conflicts with main), s4 adds h, emp (empty)
# dup: adds m like M1 does; mc: a merge commit of mx into my
sq_build() {
    local r=$1
    rm -rf "$r"; mkdir -p "$r"
    (
        set -e
        sq_env
        cd "$r"
        git init -q -b main .
        git config core.fileMode true
        git config merge.renames false
        printf 'a\nb\nc\nd\ne\nf\ng\nh\n' >f; echo k >k
        git add -A; git commit -q -m base; git tag t0
        git checkout -q -b side
        echo g1 >g; git add -A; git commit -q -m "side 1"; git tag t1
        printf 'a\nb\nc\nd\ne\nf\ng\nH\n' >f; git commit -q -am "side 2"; git tag t2
        printf 'a\nb\nTHEIRS\nd\ne\nf\ng\nH\n' >f; git commit -q -am "side 3"; git tag t3
        echo h1 >h; git add -A; git commit -q -m "side 4

with a body
Signed-off-by: A <a@example.com>"; git tag t4
        git commit -q --allow-empty -m "side empty"; git tag emp
        git checkout -q -b dup t0
        echo m >m; git add -A; git commit -q -m "dup of m"; git tag dup
        git checkout -q -b mx t0
        echo x >x; git add -A; git commit -q -m "x"
        git checkout -q -b my t0
        echo y >y; git add -A; git commit -q -m "y"
        git merge -q --no-ff -m "merge x" mx; git tag mc
        git checkout -q main
        printf 'a\nb\nOURS\nd\ne\nf\ng\nh\n' >f; echo m >m; git add -A; git commit -q -m "main 1"; git tag m1
        printf 'a\nb\nOURS2\nd\ne\nf\ng\nh\n' >f; echo n >n; git add -A; git commit -q -m "main 2"; git tag m2
        echo p >p; git add -A; git commit -q -m "main 3"; git tag m3
    ) >"$WORK/sq_fx.log" 2>&1 || { bad "sequencer: fixture" "$(tail -3 "$WORK/sq_fx.log")"; return 1; }
}

sq_twin() {
    rm -rf "$2"; cp -a "$1" "$2"
    git -C "$2" update-index -q --refresh
}

sq_snap() {
    (
        cd "$1"
        find . -name .git -prune -o \( -type f -o -type l \) -print | sort | while read -r f; do
            if [ -L "$f" ]; then echo "$f L $(readlink "$f")"; else echo "$f $(stat -c %a "$f") $(sha1sum <"$f")"; fi
        done
    )
}

sq_state() {
    local r=$1
    echo "== HEAD $(git -C "$r" rev-parse HEAD)"
    echo "== branch $(git -C "$r" symbolic-ref -q HEAD)"
    echo "== index"; git -C "$r" ls-files -s
    echo "== status"; git -C "$r" status --porcelain
    echo "== worktree"; sq_snap "$r"
    local f
    for f in CHERRY_PICK_HEAD REVERT_HEAD MERGE_HEAD MERGE_MSG ORIG_HEAD AUTO_MERGE sequencer/head sequencer/abort-safety sequencer/todo sequencer/opts; do
        if [ -e "$r/.git/$f" ]; then echo "== $f"; cat "$r/.git/$f"; else echo "== $f absent"; fi
    done
    echo "== logs/HEAD"; cut -d' ' -f1,2,5- "$r/.git/logs/HEAD" 2>/dev/null
    echo "== logs/branch"; cut -d' ' -f1,2,5- "$r/.git/logs/$(git -C "$r" symbolic-ref -q HEAD)" 2>/dev/null
}

sq_fsck() {
    if ! git -C "$1" fsck --strict >"$WORK/sq_fsck.log" 2>&1; then
        bad "sequencer: $2: fsck --strict" "$(head -3 "$WORK/sq_fsck.log")"
        return 1
    fi
}

# sq_compare <label> <pick|revert> <flags> <specs> [setup]: the same operation on two copies of $WORK/sq_src
sq_compare() {
    local label=$1 verb=$2 flags=$3 specs=$4 setup=${5:-:}
    local gverb=cherry-pick gextra=
    [ "$verb" = revert ] && { gverb=revert; gextra=--no-edit; }
    sq_twin "$WORK/sq_src" "$WORK/sq_g"; sq_twin "$WORK/sq_src" "$WORK/sq_o"
    $setup "$WORK/sq_g"; $setup "$WORK/sq_o"
    local gout grc oout
    gout=$(sq_git -C "$WORK/sq_g" $gverb $gextra ${flags//--keep-redundant/--empty=keep} $specs 2>&1); grc=$?
    oout=$(sq_ours "$WORK/sq_o" $verb $flags $specs 2>&1)
    local gs os
    gs=$(sq_state "$WORK/sq_g"); os=$(sq_state "$WORK/sq_o")
    if [ "$gs" != "$os" ]; then
        bad "sequencer: $label: state differs from git (git rc=$grc: $(echo "$gout" | tail -2 | tr '\n' ' '); ours: $(echo "$oout" | head -3 | tr '\n' ' '))" "$(diff <(echo "$gs") <(echo "$os") | head -16)"
        return 1
    fi
    sq_fsck "$WORK/sq_o" "$label" || return 1
    note "sequencer: $label (state, refs, reflogs and state files equal git's; rc=$grc; ours: $(echo "$oout" | head -1))"
}

# sq_refuse <label> <verb> <flags> <specs> <setup>: git refuses; ours must refuse and write nothing
sq_refuse() {
    local label=$1 verb=$2 flags=$3 specs=$4 setup=${5:-:}
    local gverb=cherry-pick gextra=
    [ "$verb" = revert ] && { gverb=revert; gextra=--no-edit; }
    sq_twin "$WORK/sq_src" "$WORK/sq_g"; sq_twin "$WORK/sq_src" "$WORK/sq_o"
    $setup "$WORK/sq_g"; $setup "$WORK/sq_o"
    local before gout grc oout
    before=$(sq_state "$WORK/sq_o")
    gout=$(sq_git -C "$WORK/sq_g" $gverb $gextra $flags $specs 2>&1); grc=$?
    oout=$(sq_ours "$WORK/sq_o" $verb $flags $specs 2>&1)
    if [ $grc -eq 0 ]; then bad "sequencer: $label" "test expects git to refuse, it said: $(echo "$gout" | head -2)"; return 1; fi
    case $oout in refused*) ;; *) bad "sequencer: $label" "git refused ($(echo "$gout" | head -1)), ours: $(echo "$oout" | head -2)"; return 1 ;; esac
    if [ "$before" != "$(sq_state "$WORK/sq_o")" ]; then
        bad "sequencer: $label: refusal wrote something" "$(diff <(echo "$before") <(sq_state "$WORK/sq_o") | head -8)"
        return 1
    fi
    note "sequencer: $label refused like git, nothing written (${oout#refused })"
}

sq_stage_other() { echo "staged" >>"$1/k"; git -C "$1" add k; }
sq_edit_touched() { echo "local edit" >>"$1/g"; }
sq_edit_g_new() { echo "mine" >"$1/g"; }
sq_unrelated_edit() { echo "local edit" >>"$1/k"; echo untracked >"$1/scratch.txt"; }
sq_detach() { sq_git -C "$1" checkout -q --detach; }
sq_resolve() { printf 'a\nb\nresolved\nd\ne\nf\ng\nH\n' >"$1/f"; git -C "$1" add -A; }

# sq_flow <label> <verb> <flags> <specs> <action>: git and ours each start the
# operation, then each finishes it (continue after resolving f, skip, or
# abort): four pairings, every end state equal to git alone.
sq_flow() {
    local label=$1 verb=$2 flags=$3 specs=$4 action=$5
    local gverb=cherry-pick gextra=
    [ "$verb" = revert ] && { gverb=revert; gextra=--no-edit; }
    local d x y
    for d in gg go og oo; do sq_twin "$WORK/sq_src" "$WORK/sq_f$d"; done
    for d in gg go og oo; do
        x=${d:0:1}
        if [ "$x" = g ]; then sq_git -C "$WORK/sq_f$d" $gverb $gextra $flags $specs >/dev/null 2>&1
        else sq_ours "$WORK/sq_f$d" $verb $flags $specs >/dev/null 2>&1; fi
    done
    local base
    base=$(sq_state "$WORK/sq_fgg")
    for d in go og oo; do
        if [ "$base" != "$(sq_state "$WORK/sq_f$d")" ]; then bad "sequencer: $label: start state ($d) differs" "$(diff <(echo "$base") <(sq_state "$WORK/sq_f$d") | head -10)"; return 1; fi
    done
    if [ ! -e "$WORK/sq_fgg/.git/CHERRY_PICK_HEAD" ] && [ ! -e "$WORK/sq_fgg/.git/REVERT_HEAD" ]; then
        bad "sequencer: $label: flow needs a stopped operation"; return 1
    fi
    [ "$action" = continue ] && for d in gg go og oo; do sq_resolve "$WORK/sq_f$d"; done
    local out
    for d in gg go og oo; do
        y=${d:1:1}
        if [ "$y" = g ]; then
            sq_git -C "$WORK/sq_f$d" $gverb --$action >"$WORK/sq_fin.log" 2>&1 || true
        else
            out=$(sq_ours "$WORK/sq_f$d" $action 2>&1)
            case $out in refused*) bad "sequencer: $label: our $action ($d)" "$out"; return 1 ;; esac
        fi
    done
    local want
    want=$(sq_state "$WORK/sq_fgg")
    for d in go og oo; do
        if [ "$want" != "$(sq_state "$WORK/sq_f$d")" ]; then bad "sequencer: $label: $action state (start/finish $d) differs from git's" "$(diff <(echo "$want") <(sq_state "$WORK/sq_f$d") | head -12)"; return 1; fi
    done
    sq_fsck "$WORK/sq_foo" "$label $action" || return 1
    note "sequencer: $label: $action by git, by ours, ours on git's state and git on ours all end equal ($(git -C "$WORK/sq_fgg" rev-parse --short HEAD))"
}

if build t_sequencer; then
    sq_build "$WORK/sq_src" &&
    {
        # --- single commits
        sq_compare "pick, clean" pick "" t1
        sq_compare "pick -x, clean" pick "-x" t1
        sq_compare "pick -x, message with trailers" pick "-x" t4
        sq_compare "pick -n" pick "-n" t1
        sq_compare "pick -n -x" pick "-n -x" t1
        sq_compare "pick, conflict" pick "" t3
        sq_compare "pick -x, conflict" pick "-x" t3
        sq_compare "pick -n, conflict" pick "-n" t3
        sq_compare "pick on a detached HEAD" pick "" t1 sq_detach
        sq_compare "pick, unrelated local edit and untracked file" pick "" t1 sq_unrelated_edit
        sq_compare "pick of a merge commit, -m 1" pick "-m 1" mc
        sq_compare "pick, -m on a commit that is not a merge is ignored" pick "-m 1" t1
        sq_compare "revert, -m on a commit that is not a merge is ignored" revert "-m 1" m3
        sq_compare "pick of a merge commit, -m 2" pick "-m 2" mc
        sq_compare "pick of an empty commit stops" pick "" emp
        sq_compare "pick of an empty commit, --allow-empty" pick "--allow-empty" emp
        sq_compare "pick of a redundant commit stops" pick "" dup
        sq_compare "pick of a redundant commit, --keep-redundant-commits" pick "--keep-redundant" dup
        sq_compare "pick of a redundant commit, --allow-empty still stops" pick "--allow-empty" dup
        sq_compare "revert, clean" revert "" m3
        sq_compare "revert, conflict" revert "" m1
        sq_compare "revert -n" revert "-n" m3
        sq_compare "revert -n, conflict" revert "-n" m1
        # --- ranges
        sq_compare "range pick, clean" pick "" "t0..t2"
        sq_compare "range pick of one commit keeps the sequencer" pick "" "t0..t1"
        sq_compare "range pick, stops on a conflict" pick "" "t0..t4"
        sq_compare "range pick -x" pick "-x" "t0..t2"
        sq_compare "range pick -n" pick "-n" "t0..t2"
        sq_compare "range pick -n -x, stops on a conflict" pick "-n -x" "t0..t4"
        sq_compare "two commits named, in the order given" pick "" "t2 t1"
        sq_compare "range with an empty commit stops there" pick "" "t4..emp"
        sq_compare "range with an empty commit, --allow-empty" pick "--allow-empty" "t3..emp"
        sq_compare "range revert, newest first" revert "" "m1..m3"
        sq_compare "two commits reverted, the first conflicts" revert "" "m1 m3"
        sq_compare "range revert -n" revert "-n" "m1..m3"
        # --- the revision grammar (GIT_revparse) in the words
        sq_compare "pick of an ancestor of a branch, side~3" pick "" "side~3"
        sq_compare "pick of an ancestor of a branch, conflict, side~2" pick "" "side~2"
        sq_compare "pick of a first parent, t2^" pick "" "t2^"
        sq_compare "pick by a message search, side^{/side 1}" pick "" "side^{/side 1}"
        sq_compare "range from a suffixed revision, t4~3..t4" pick "" "t4~3..t4"
        sq_compare "range with an empty right side is HEAD, t0.." pick "" "t0.."
        sq_compare "range as ^A B" pick "" "^t0 t2"
        sq_compare "one-commit range, t1^!" pick "" "t1^!"
        sq_compare "symmetric difference, t2...t3" pick "" "t2...t3"
        sq_compare "range revert from a suffixed revision, m3~2..m3" revert "" "m3~2..m3"
        sq_compare "revert by ancestor, m3~1" revert "" "m3~1"
        # --- refusals
        sq_refuse "pick with a staged change elsewhere" pick "" t1 sq_stage_other
        sq_refuse "pick over a local edit of a touched file" pick "" t1 sq_edit_touched
        sq_refuse "pick, merge commit without -m" pick "" mc
        sq_refuse "pick, mainline past the parents" pick "-m 3" mc
        sq_refuse "range pick with a staged change elsewhere" pick "" "t0..t2" sq_stage_other
        # --- finishing, skipping and aborting what was started
        sq_flow "single pick, conflict" pick "" t3 continue
        sq_flow "single pick, conflict" pick "" t3 skip
        sq_flow "single pick, conflict" pick "" t3 abort
        sq_flow "single pick -x, conflict" pick "-x" t3 continue
        sq_flow "single revert, conflict" revert "" m1 continue
        sq_flow "single revert, conflict" revert "" m1 skip
        sq_flow "single revert, conflict" revert "" m1 abort
        sq_flow "range pick t0..t4, conflict on the third" pick "" "t0..t4" continue
        sq_flow "range pick t0..t4, conflict on the third" pick "" "t0..t4" skip
        sq_flow "range pick t0..t4, conflict on the third" pick "" "t0..t4" abort
        sq_flow "range pick -x t0..t4" pick "-x" "t0..t4" continue
        sq_flow "two reverts, the first conflicts" revert "" "m1 m3" continue
        sq_flow "two reverts, the first conflicts" revert "" "m1 m3" skip
        sq_flow "two reverts, the first conflicts" revert "" "m1 m3" abort
    }
fi

# The cherry-pick and revert screens under a real pty (`pty_sequencer.py`): the menus from a
# commit or branch row, the banner, blocked operations, resolution, continue/skip/abort/quit and
# git interop, each checked against real git. It builds its own fixtures under `$WORK/pty_sequencer`.
if [ -f "$WORK/gitui" ] || bash scripts/build-gitui.sh -o "$WORK/gitui_sequencer" >"$WORK/gitui_sequencer_build.log" 2>&1; then
    [ -f "$WORK/gitui" ] && sq_bin="$WORK/gitui" || sq_bin="$WORK/gitui_sequencer"
    if command -v python3 >/dev/null; then
        if out=$(python3 tests/pty_sequencer.py "$sq_bin" "$WORK/pty_sequencer" 2>&1); then
            note "sequencer pty: $(echo "$out" | grep -c '^ok') cherry-pick and revert screen checks passed under a real pty"
        else
            bad "sequencer pty" "$out"
        fi
    else
        echo "sequencer pty: skipped, no python3" >&2
    fi
else
    bad "sequencer pty: scripts/build-gitui.sh" "$(cat "$WORK/gitui_sequencer_build.log")"
fi
