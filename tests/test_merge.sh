# GIT_merge, against real git as the oracle in disposable fixtures. Shares
# `test.sh`'s shell, `$WORK`, `$LANGC`, `build`, `note`/`bad` and the counters.
#
#   1. merge_trees: the merged tree id and the index stages equal
#      `git merge-tree --write-tree` (renames off) for a table of cases.
#   2. start/continue/abort/ff: working tree, index, refs, reflogs and the
#      state files after our merge equal those after `git merge`, `git fsck
#      --strict` is clean, and git finishes what we start and we finish what
#      git started.

mg_env() {
    export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
    export GIT_AUTHOR_DATE='1700000000 +0000' GIT_COMMITTER_DATE='1700000000 +0000'
}

# --- 1. merge_trees against git merge-tree -----------------------------------------
#
# mt_case <label> <style> <base cmds> <ours cmds> <theirs cmds>: one repo with
# commits base, ours (main) and theirs (side), the commands run in the work
# tree before `git add -A && git commit`.

mt_case() {
    local label=$1 style=$2 base=$3 ours=$4 theirs=$5
    local r="$WORK/mt_repo"
    rm -rf "$r"; mkdir -p "$r"
    (
        set -e
        mg_env
        cd "$r"
        git init -q -b base .
        git config core.fileMode true
        git config merge.renames false
        [ "$style" = diff3 ] && git config merge.conflictstyle diff3
        eval "$base"
        git add -A; git commit -q --allow-empty -m base
        git checkout -q -b main
        eval "$ours"
        git add -A; git commit -q --allow-empty -m ours
        git checkout -q -b side base
        eval "$theirs"
        git add -A; git commit -q --allow-empty -m theirs
        git checkout -q main
    ) >"$WORK/mt_fx.log" 2>&1 || { bad "merge_trees: $label: fixture" "$(tail -3 "$WORK/mt_fx.log")"; return; }
    local gout gtree gstages otree ostages
    gout=$(git -C "$r" -c core.quotepath=false merge-tree --write-tree --merge-base=base main side 2>/dev/null)
    gtree=$(printf '%s\n' "$gout" | head -1)
    gstages=$(printf '%s\n' "$gout" | sed -n '2,/^$/p' | grep -v '^$' | sort -k4,4 -k3,3n)
    local out
    out=$("$WORK/t_merge" "$r/.git" trees "$(git -C "$r" rev-parse base)" "$(git -C "$r" rev-parse main)" "$(git -C "$r" rev-parse side)" main side base ${style/merge/} 2>&1)
    otree=$(printf '%s\n' "$out" | sed -n 's/^tree //p' | head -1)
    ostages=$(printf '%s\n' "$out" | sed -n 's/^stage //p' | sort -k4,4 -k3,3n)
    if [ "$gtree" != "$otree" ]; then
        bad "merge_trees: $label: tree differs from git" "git $gtree ours $otree
$(diff <(git -C "$r" ls-tree -r "$gtree" 2>&1) <(git -C "$r" ls-tree -r "$otree" 2>&1) | head -8)
$(echo "$out" | head -4)"
        return
    fi
    if [ "$gstages" != "$ostages" ]; then
        bad "merge_trees: $label: stages differ from git" "$(diff <(echo "$gstages") <(echo "$ostages") | head -8)"
        return
    fi
    if ! git -C "$r" fsck --strict >"$WORK/mt_fsck.log" 2>&1; then
        bad "merge_trees: $label: fsck" "$(head -3 "$WORK/mt_fsck.log")"
        return
    fi
    note "merge_trees: $label ($(echo "$ostages" | grep -c .) stages, tree equals git's)"
}

if build t_merge; then
    L=$'a\nb\nc\nd\ne\nf\ng\nh\n'
    mt_case "one-sided edit and add" merge "printf '$L' >f; echo x >g" "echo y >h" "printf 'A\nb\nc\nd\ne\nf\ng\nh\n' >f"
    mt_case "both edit, apart" merge "printf '$L' >f" "printf 'A\nb\nc\nd\ne\nf\ng\nh\n' >f" "printf 'a\nb\nc\nd\ne\nf\ng\nH\n' >f"
    mt_case "both edit, same line (conflict)" merge "printf '$L' >f" "printf 'a\nb\nOURS\nd\ne\nf\ng\nh\n' >f" "printf 'a\nb\nTHEIRS\nd\ne\nf\ng\nh\n' >f"
    mt_case "both edit, same line, diff3 style" diff3 "printf '$L' >f" "printf 'a\nb\nOURS\nd\ne\nf\ng\nh\n' >f" "printf 'a\nb\nTHEIRS\nd\ne\nf\ng\nh\n' >f"
    mt_case "identical change on both sides" merge "printf '$L' >f" "echo same >f" "echo same >f"
    mt_case "both delete" merge "echo a >f; echo k >k" "rm f" "rm f"
    mt_case "add/add identical" merge "echo k >k" "echo n >n" "echo n >n"
    mt_case "add/add different (conflict)" merge "echo k >k" "echo ours >n" "echo theirs >n"
    mt_case "add/add similar content merges with markers" merge "echo k >k" "printf 'x\ny\nz\n' >n" "printf 'x\nY\nz\n' >n"
    mt_case "modify/delete" merge "printf '$L' >f; echo k >k" "echo changed >f" "rm f"
    mt_case "delete/modify" merge "printf '$L' >f; echo k >k" "rm f" "echo changed >f"
    mt_case "delete on one side, untouched on the other" merge "echo f >f; echo k >k" "rm f" "echo kk >k"
    mt_case "mode change on one side" merge "echo f >f" "chmod +x f" "echo more >>f"
    mt_case "mode change on one side, content on other" merge "printf '$L' >f" "chmod +x f" "printf 'A\nb\nc\nd\ne\nf\ng\nh\n' >f"
    mt_case "mode change identical" merge "echo f >f" "chmod +x f" "chmod +x f"
    mt_case "binary file changed on both sides" merge "printf 'a\0b' >bin" "printf 'a\0o' >bin" "printf 'a\0t' >bin"
    mt_case "binary file changed on one side" merge "printf 'a\0b' >bin" "printf 'a\0o' >bin" "echo k >k"
    mt_case "symlink changed on both sides" merge "ln -s t0 l" "ln -sf t1 l" "ln -sf t2 l"
    mt_case "symlink changed on one side" merge "ln -s t0 l" "ln -sf t1 l" "echo k >k"
    mt_case "symlink added on both, same target" merge "echo k >k" "ln -s t l" "ln -s t l"
    mt_case "file becomes dir on ours" merge "echo f >f; echo k >k" "rm f; mkdir f; echo in >f/in" "echo edited >f"
    mt_case "file becomes dir on theirs" merge "echo f >f; echo k >k" "echo edited >f" "rm f; mkdir f; echo in >f/in"
    mt_case "dir added on ours, file added on theirs" merge "echo k >k" "mkdir d; echo in >d/in" "echo file >d"
    mt_case "file added on ours, dir added on theirs" merge "echo k >k" "echo file >d" "mkdir d; echo in >d/in"
    mt_case "file against dir, file unchanged vs base" merge "echo f >f; echo k >k" "rm f; mkdir f; echo in >f/in" "echo k2 >k"
    mt_case "file vs symlink added" merge "echo k >k" "echo plain >p" "ln -s tgt p"
    mt_case "symlink vs file added" merge "echo k >k" "ln -s tgt p" "echo plain >p"
    mt_case "file becomes symlink on theirs, edited on ours" merge "echo f >f" "echo edited >f" "rm f; ln -s tgt f"
    mt_case "dir in dir: edits in different files" merge "mkdir -p d/e; echo 1 >d/e/x; echo 2 >d/y" "echo 11 >d/e/x" "echo 22 >d/y"
    mt_case "dir deleted on ours, file in it edited on theirs" merge "mkdir d; echo 1 >d/x; echo 2 >d/y; echo k >k" "git rm -rq d" "echo 11 >d/x"
    mt_case "dir deleted on both, one file added on theirs" merge "mkdir d; echo 1 >d/x; echo k >k" "git rm -rq d" "git rm -rq d; mkdir d; echo n >d/new"
    mt_case "whole dir added on both with one conflict" merge "echo k >k" "mkdir d; echo a >d/a; echo o >d/c" "mkdir d; echo a >d/a; echo t >d/c"
    mt_case "empty tree on one side" merge "echo k >k" "git rm -q k" "echo z >z"
    mt_case "ours already contains theirs' change" merge "echo a >f" "echo b >f" "echo a >f"
    mt_case "CRLF files merge" merge "printf 'a\r\nb\r\nc\r\n' >f" "printf 'A\r\nb\r\nc\r\n' >f" "printf 'a\r\nb\r\nC\r\n' >f"
    mt_case "no trailing newline conflict" merge "printf 'a\nb' >f" "printf 'a\nbo' >f" "printf 'a\nbt' >f"
    mt_case "unicode and space path" merge "mkdir 'dir é'; echo 1 >'dir é/f g'" "echo 2 >'dir é/f g'" "echo 3 >'dir é/f g'"
    mt_case "two conflicts in one file" diff3 "printf '$L' >f" "printf 'O1\nb\nc\nd\ne\nf\ng\nO2\n' >f" "printf 'T1\nb\nc\nd\ne\nf\ng\nT2\n' >f"
fi

# --- 2. whole merges against git merge ------------------------------------------------
#
# mg_build <dir> <style> <base cmds> <ours cmds> <theirs cmds> makes a repository
# with branches base, main (checked out) and side. mg_twin copies it; one copy
# gets `git merge`, the other our t_merge, and everything observable is compared.

mg_git() { ( mg_env; git "$@" ); }
mg_ours() { ( mg_env; "$WORK/t_merge" "$@" ); }

mg_build() {
    local r=$1 style=$2 base=$3 ours=$4 theirs=$5 head_branch=${6:-main}
    rm -rf "$r"; mkdir -p "$r"
    (
        set -e
        mg_env
        cd "$r"
        git init -q -b base .
        git config core.fileMode true
        git config merge.renames false
        [ "$style" = diff3 ] && git config merge.conflictstyle diff3
        eval "$base"
        git add -A; git commit -q --allow-empty -m base
        git checkout -q -b "$head_branch"
        eval "$ours"
        git add -A; git commit -q --allow-empty -m ours
        git checkout -q -b side base
        eval "$theirs"
        git add -A; git commit -q --allow-empty -m theirs
        git checkout -q "$head_branch"
    ) >"$WORK/mg_fx.log" 2>&1 || { bad "merge: fixture" "$(tail -3 "$WORK/mg_fx.log")"; return 1; }
}

mg_twin() {
    rm -rf "$2"; cp -a "$1" "$2"
    git -C "$2" update-index -q --refresh
}

mg_snap() {
    (
        cd "$1"
        find . -name .git -prune -o \( -type f -o -type l \) -print | sort | while read -r f; do
            if [ -L "$f" ]; then echo "$f L $(readlink "$f")"; else echo "$f $(stat -c %a "$f") $(sha1sum <"$f")"; fi
        done
    )
}

# everything observable about a repository, one text blob
mg_state() {
    local r=$1
    echo "== HEAD $(git -C "$r" rev-parse HEAD)"
    echo "== branch $(git -C "$r" symbolic-ref -q HEAD)"
    echo "== index"; git -C "$r" ls-files -s
    echo "== status"; git -C "$r" status --porcelain
    echo "== worktree"; mg_snap "$r"
    local f
    for f in MERGE_HEAD MERGE_MODE MERGE_MSG ORIG_HEAD AUTO_MERGE; do
        if [ -e "$r/.git/$f" ]; then echo "== $f"; cat "$r/.git/$f"; else echo "== $f absent"; fi
    done
    echo "== logs/HEAD"; cut -d' ' -f1,2,5- "$r/.git/logs/HEAD" 2>/dev/null
    echo "== logs/branch"; cut -d' ' -f1,2,5- "$r/.git/logs/$(git -C "$r" symbolic-ref -q HEAD)" 2>/dev/null
}

mg_check_fsck() {
    if ! git -C "$1" fsck --strict >"$WORK/mg_fsck.log" 2>&1; then
        bad "merge: $2: fsck --strict" "$(head -3 "$WORK/mg_fsck.log")"
        return 1
    fi
}

# mg_compare <label> <git flags> <our flags> : the same merge on two copies of $WORK/mg_src
mg_compare() {
    local label=$1 gflags=$2 oflags=$3 setup=${4:-:}
    mg_twin "$WORK/mg_src" "$WORK/mg_g"; mg_twin "$WORK/mg_src" "$WORK/mg_o"
    $setup "$WORK/mg_g"; $setup "$WORK/mg_o"
    local gout grc oout
    gout=$(mg_git -C "$WORK/mg_g" merge --no-edit $gflags side 2>&1); grc=$?
    oout=$(mg_ours "$WORK/mg_o/.git" "$WORK/mg_o" merge side $oflags 2>&1)
    local gs os
    gs=$(mg_state "$WORK/mg_g"); os=$(mg_state "$WORK/mg_o")
    if [ "$gs" != "$os" ]; then
        bad "merge: $label: state differs from git (git rc=$grc: $(echo "$gout" | tail -2 | tr '\n' ' '); ours: $(echo "$oout" | head -3 | tr '\n' ' '))" "$(diff <(echo "$gs") <(echo "$os") | head -14)"
        return 1
    fi
    mg_check_fsck "$WORK/mg_o" "$label" || return 1
    note "merge: $label (state, refs, reflogs and state files equal git's; rc=$grc; ours: $(echo "$oout" | head -1))"
}

# mg_refuse <label> <git flags> <our flags> <setup> : git refuses; ours must refuse and write nothing
mg_refuse() {
    local label=$1 gflags=$2 oflags=$3 setup=${4:-:}
    mg_twin "$WORK/mg_src" "$WORK/mg_g"; mg_twin "$WORK/mg_src" "$WORK/mg_o"
    $setup "$WORK/mg_g"; $setup "$WORK/mg_o"
    local before gout grc oout
    before=$(mg_state "$WORK/mg_o")
    gout=$(mg_git -C "$WORK/mg_g" merge --no-edit $gflags side 2>&1); grc=$?
    oout=$(mg_ours "$WORK/mg_o/.git" "$WORK/mg_o" merge side $oflags 2>&1)
    if [ $grc -eq 0 ]; then bad "merge: $label" "test expects git to refuse, it said: $(echo "$gout" | head -2)"; return 1; fi
    case $oout in refused*) ;; *) bad "merge: $label" "git refused ($(echo "$gout" | head -1)), ours: $(echo "$oout" | head -2)"; return 1 ;; esac
    if [ "$before" != "$(mg_state "$WORK/mg_o")" ]; then
        bad "merge: $label: refusal wrote something" "$(diff <(echo "$before") <(mg_state "$WORK/mg_o") | head -8)"
        return 1
    fi
    note "merge: $label refused like git, nothing written (${oout#refused })"
}

mg_unrelated_edit() { echo "local edit" >>"$1/k"; echo "untracked" >"$1/scratch.txt"; }
mg_edit_touched() { echo "local edit" >>"$1/f"; }
mg_stage_other() { echo "staged" >>"$1/k"; git -C "$1" add k; }
mg_untracked_in_way() { echo mine >"$1/theirs_new"; }
mg_edit_other() { echo "local edit" >>"$1/k"; }
mg_detach() { git -C "$1" checkout -q --detach; }

# mg_flow <label> : on $WORK/mg_src (which must conflict), git and ours each start
# the merge, then finish it (resolve everything with `git add -A`, then git's
# `commit` or our `continue`) or abort it, in all four pairings; every end
# state must equal the one git reaches on its own.
mg_flow() {
    local label=$1 extra=${2:-:}
    local d
    for d in gg go og oo; do mg_twin "$WORK/mg_src" "$WORK/mg_f$d"; done
    local gstart ostart
    mg_git -C "$WORK/mg_fgg" merge --no-edit side >/dev/null 2>&1; mg_git -C "$WORK/mg_fgo" merge --no-edit side >/dev/null 2>&1
    mg_ours "$WORK/mg_fog/.git" "$WORK/mg_fog" merge side >/dev/null 2>&1; mg_ours "$WORK/mg_foo/.git" "$WORK/mg_foo" merge side >/dev/null 2>&1
    if [ ! -e "$WORK/mg_fgg/.git/MERGE_HEAD" ] || [ ! -e "$WORK/mg_fog/.git/MERGE_HEAD" ]; then
        bad "merge: $label: flow needs a conflicting merge" "git: $(ls "$WORK/mg_fgg/.git" | grep -c MERGE_HEAD) ours: $(ls "$WORK/mg_fog/.git" | grep -c MERGE_HEAD)"
        return 1
    fi
    # the four starts agree
    local base
    base=$(mg_state "$WORK/mg_fgg")
    for d in go og oo; do
        if [ "$base" != "$(mg_state "$WORK/mg_f$d")" ]; then bad "merge: $label: start state ($d) differs" "$(diff <(echo "$base") <(mg_state "$WORK/mg_f$d") | head -8)"; return 1; fi
    done
    # --- abort: git/git, git/ours, ours/git, ours/ours
    for d in gg go og oo; do $extra "$WORK/mg_f$d"; done
    mg_git -C "$WORK/mg_fgg" merge --abort >"$WORK/mg_ab.log" 2>&1 || { bad "merge: $label: git merge --abort failed" "$(head -3 "$WORK/mg_ab.log")"; return 1; }
    mg_git -C "$WORK/mg_fog" merge --abort >/dev/null 2>&1
    local out
    out=$(mg_ours "$WORK/mg_fgo/.git" "$WORK/mg_fgo" abort 2>&1); mg_ours "$WORK/mg_foo/.git" "$WORK/mg_foo" abort >/dev/null 2>&1
    case $out in aborted) ;; *) bad "merge: $label: our abort of git's merge" "$out"; return 1 ;; esac
    local want
    want=$(mg_state "$WORK/mg_fgg")
    for d in go og oo; do
        if [ "$want" != "$(mg_state "$WORK/mg_f$d")" ]; then bad "merge: $label: abort state (git start/$d) differs from git's abort" "$(diff <(echo "$want") <(mg_state "$WORK/mg_f$d") | head -10)"; return 1; fi
    done
    mg_check_fsck "$WORK/mg_foo" "$label abort" || return 1
    note "merge: $label: abort by git, by ours, ours on git's state and git on ours all end equal"
    # --- continue
    for d in gg go og oo; do mg_twin "$WORK/mg_src" "$WORK/mg_f$d"; done
    mg_git -C "$WORK/mg_fgg" merge --no-edit side >/dev/null 2>&1; mg_git -C "$WORK/mg_fgo" merge --no-edit side >/dev/null 2>&1
    mg_ours "$WORK/mg_fog/.git" "$WORK/mg_fog" merge side >/dev/null 2>&1; mg_ours "$WORK/mg_foo/.git" "$WORK/mg_foo" merge side >/dev/null 2>&1
    for d in gg go og oo; do $extra "$WORK/mg_f$d"; git -C "$WORK/mg_f$d" add -A; done
    out=$(mg_ours "$WORK/mg_fgo/.git" "$WORK/mg_fgo" continue 2>&1)
    case $out in "ending merged"*) ;; *) bad "merge: $label: our continue of git's merge" "$out"; return 1 ;; esac
    mg_ours "$WORK/mg_foo/.git" "$WORK/mg_foo" continue >/dev/null 2>&1
    mg_git -C "$WORK/mg_fgg" commit -q --no-edit --cleanup=strip >"$WORK/mg_ab.log" 2>&1 || { bad "merge: $label: git commit failed" "$(head -3 "$WORK/mg_ab.log")"; return 1; }
    mg_git -C "$WORK/mg_fog" commit -q --no-edit --cleanup=strip >/dev/null 2>&1
    want=$(mg_state "$WORK/mg_fgg")
    for d in go og oo; do
        if [ "$want" != "$(mg_state "$WORK/mg_f$d")" ]; then bad "merge: $label: continue state (start/finish $d) differs from git's" "$(diff <(echo "$want") <(mg_state "$WORK/mg_f$d") | head -10)"; return 1; fi
    done
    if [ "$(git -C "$WORK/mg_fgg" rev-list --parents -1 HEAD | wc -w)" != 3 ]; then bad "merge: $label: merge commit has not two parents"; return 1; fi
    mg_check_fsck "$WORK/mg_foo" "$label continue" || return 1
    note "merge: $label: git finishes our merge and we finish git's, same commit id as git alone ($(git -C "$WORK/mg_fgg" rev-parse --short HEAD))"
    # --- continue with unmerged paths refuses
    mg_twin "$WORK/mg_src" "$WORK/mg_foo"
    mg_ours "$WORK/mg_foo/.git" "$WORK/mg_foo" merge side >/dev/null 2>&1
    out=$(mg_ours "$WORK/mg_foo/.git" "$WORK/mg_foo" continue 2>&1)
    case $out in "refused committing is not possible"*) note "merge: $label: continue with unmerged paths refused" ;; *) bad "merge: $label: continue while unmerged" "$out" ;; esac
}

if [ -f "$WORK/t_merge" ]; then
    L=$'a\nb\nc\nd\ne\nf\ng\nh\n'
    mg_build "$WORK/mg_src" merge "printf '$L' >f; echo k >k" "echo o >ours_new; printf 'a\nb\nc\nd\ne\nf\ng\nH\n' >f" "echo t >theirs_new; printf 'A\nb\nc\nd\ne\nf\ng\nh\n' >f" &&
    {
        mg_compare "clean merge of two branches" "" ""
        mg_compare "--no-ff on a clean merge" "--no-ff" "--no-ff"
        mg_compare "unrelated local edit and untracked file survive a clean merge" "" "" mg_unrelated_edit
        mg_compare "merge on a detached HEAD" "" "" mg_detach
        mg_refuse "staged change elsewhere (index != HEAD)" "" "" mg_stage_other
        mg_refuse "local edit of a touched file" "" "" mg_edit_touched
        mg_refuse "untracked file where a new file goes" "" "" mg_untracked_in_way
        mg_refuse "--ff-only on diverged branches" "--ff-only" "--ff-only"
    }
    mg_build "$WORK/mg_src" merge "printf '$L' >f; echo k >k" "printf 'a\nb\nOURS\nd\ne\nf\ng\nh\n' >f" "printf 'a\nb\nTHEIRS\nd\ne\nf\ng\nh\n' >f" &&
    {
        mg_compare "content conflict" "" ""
        mg_compare "content conflict, --no-ff" "--no-ff" "--no-ff"
        mg_compare "content conflict with unrelated local edit" "" "" mg_unrelated_edit
        mg_flow "content conflict"
        mg_flow "content conflict, with an unrelated edit and staged change around" mg_unrelated_edit
    }
    mg_build "$WORK/mg_src" diff3 "printf '$L' >f; echo k >k" "printf 'a\nb\nOURS\nd\ne\nf\ng\nh\n' >f" "printf 'a\nb\nTHEIRS\nd\ne\nf\ng\nh\n' >f" &&
    mg_compare "content conflict, merge.conflictstyle=diff3" "" ""
    mg_build "$WORK/mg_src" merge "echo f >f; echo g >g; echo k >k" "echo changed >f; rm g" "rm f; echo changed >g" &&
    {
        mg_compare "modify/delete and delete/modify" "" ""
        mg_flow "modify/delete and delete/modify"
    }
    mg_build "$WORK/mg_src" merge "echo k >k" "echo o >n; mkdir d; echo in >d/in" "echo t >n; echo file >d" &&
    {
        mg_compare "add/add and file/directory" "" ""
        mg_flow "add/add and file/directory"
    }
    mg_build "$WORK/mg_src" merge "echo f >f; echo k >k" "rm f; mkdir f; echo in >f/in" "echo edited >f" &&
    {
        mg_compare "file replaced by a directory on ours" "" ""
        mg_flow "file replaced by a directory on ours"
    }
    mg_build "$WORK/mg_src" merge "echo f >f; echo k >k" "echo edited >f" "rm f; mkdir f; echo in >f/in" &&
    {
        mg_compare "file replaced by a directory on theirs" "" ""
        mg_flow "file replaced by a directory on theirs"
    }
    mg_build "$WORK/mg_src" merge "echo k >k; ln -s t0 l" "ln -sf t1 l; echo o >p" "ln -sf t2 l; ln -s tgt p" &&
    {
        mg_compare "symlink conflicts and file vs symlink" "" ""
        mg_flow "symlink conflicts and file vs symlink"
    }
    mg_build "$WORK/mg_src" merge "printf 'a\0b' >bin; echo k >k" "printf 'a\0o' >bin" "printf 'a\0t' >bin" &&
    {
        mg_compare "binary conflict" "" ""
        mg_flow "binary conflict"
    }
fi

# mg_raw <dir> <script> : a repository built by an arbitrary script (run inside it, fixed identity)
mg_raw() {
    local r=$1 script=$2
    rm -rf "$r"; mkdir -p "$r"
    (
        set -e
        mg_env
        cd "$r"
        git init -q -b main .
        git config merge.renames false
        eval "$script"
    ) >"$WORK/mg_fx.log" 2>&1 || { bad "merge: fixture" "$(tail -3 "$WORK/mg_fx.log")"; return 1; }
}
mg_c() { echo "$1" >"$2"; git add -A; git commit -q -m "$3"; }

if [ -f "$WORK/t_merge" ]; then
    # fast-forward, up to date, unrelated histories, message kinds
    mg_raw "$WORK/mg_src" 'printf "1\n" >f; echo k >k; git add -A; git commit -q -m c1; git checkout -q -b side; mg_c 2 f c2; mg_c 3 g c3; git checkout -q main' &&
    {
        mg_compare "fast-forward" "" ""
        mg_compare "fast-forward with --no-ff" "--no-ff" "--no-ff"
        mg_compare "fast-forward with --ff-only" "--ff-only" "--ff-only"
        mg_compare "fast-forward with an unrelated local edit" "" "" mg_edit_other
    }
    mg_raw "$WORK/mg_src" 'printf "1\n" >f; git add -A; git commit -q -m c1; git checkout -q -b side; git checkout -q main; mg_c 2 f c2' &&
    mg_compare "already up to date" "" ""
    mg_raw "$WORK/mg_src" 'echo 1 >f; git add -A; git commit -q -m c1; git checkout -q --orphan side; git rm -rq -f .; echo 2 >g; git add -A; git commit -q -m other; git checkout -q main' &&
    {
        mg_refuse "unrelated histories" "" ""
        mg_compare "unrelated histories with the allow flag" "--allow-unrelated-histories" "--unrelated"
    }
    mg_raw "$WORK/mg_src" 'echo 1 >f; git add -A; git commit -q -m c1; git checkout -q -b side; mg_c 2 g c2; git checkout -q main; mg_c 3 h c3; git branch -m master' &&
    mg_compare "message on master has no 'into'" "" ""
    mg_raw "$WORK/mg_src" 'echo 1 >f; git add -A; git commit -q -m c1; git checkout -q -b other; git checkout -q -b side; mg_c 2 g c2; git checkout -q other; mg_c 3 h c3' &&
    mg_compare "message names the branch merged into" "" ""
    mg_raw "$WORK/mg_src" 'echo 1 >f; git add -A; git commit -q -m c1; git checkout -q -b s; mg_c 2 g c2; git tag side; git checkout -q main; mg_c 3 h c3' &&
    mg_compare "merge a tag" "" ""
    mg_raw "$WORK/mg_src" 'echo 1 >f; git add -A; git commit -q -m c1; git checkout -q -b s; mg_c 2 g c2; git update-ref refs/remotes/origin/side HEAD; git checkout -q main; mg_c 3 h c3; git branch -D s' &&
    {
        mg_twin "$WORK/mg_src" "$WORK/mg_g"; mg_twin "$WORK/mg_src" "$WORK/mg_o"
        mg_git -C "$WORK/mg_g" merge --no-edit origin/side >/dev/null 2>&1
        mg_ours "$WORK/mg_o/.git" "$WORK/mg_o" merge origin/side >/dev/null 2>&1
        if [ "$(mg_state "$WORK/mg_g")" = "$(mg_state "$WORK/mg_o")" ]; then note "merge: a remote-tracking branch (message and reflog equal git's)"; else bad "merge: a remote-tracking branch" "$(diff <(mg_state "$WORK/mg_g") <(mg_state "$WORK/mg_o") | head -8)"; fi
    }
    # a second merge while one is in progress is refused
    mg_build "$WORK/mg_src" merge "echo k >k; echo 1 >f" "echo o >f" "echo t >f" &&
    {
        mg_twin "$WORK/mg_src" "$WORK/mg_o"
        mg_ours "$WORK/mg_o/.git" "$WORK/mg_o" merge side >/dev/null 2>&1
        out=$(mg_ours "$WORK/mg_o/.git" "$WORK/mg_o" merge side 2>&1)
        case $out in refused*) note "merge: a merge while one is in progress is refused (${out#refused })" ;; *) bad "merge: second merge during a merge" "$out" ;; esac
        out=$(mg_ours "$WORK/mg_src/.git" "$WORK/mg_src" continue 2>&1)
        case $out in refused*) note "merge: continue without a merge is refused (${out#refused })" ;; *) bad "merge: continue without a merge" "$out" ;; esac
        out=$(mg_ours "$WORK/mg_src/.git" "$WORK/mg_src" abort 2>&1)
        case $out in refused*) note "merge: abort without a merge is refused (${out#refused })" ;; *) bad "merge: abort without a merge" "$out" ;; esac
    }
    # a hand-resolved file committed by real git while an unrelated change is staged
    mg_build "$WORK/mg_src" merge "printf '$L' >f; echo k >k" "printf 'a\nb\nOURS\nd\ne\nf\ng\nh\n' >f" "printf 'a\nb\nTHEIRS\nd\ne\nf\ng\nh\n' >f" &&
    {
        mg_twin "$WORK/mg_src" "$WORK/mg_g"; mg_twin "$WORK/mg_src" "$WORK/mg_o"
        mg_ours "$WORK/mg_o/.git" "$WORK/mg_o" merge side >/dev/null 2>&1
        mg_git -C "$WORK/mg_g" merge --no-edit side >/dev/null 2>&1
        for d in mg_g mg_o; do printf 'a\nb\nBOTH\nd\ne\nf\ng\nh\n' >"$WORK/$d/f"; git -C "$WORK/$d" add f; done
        mg_git -C "$WORK/mg_o" commit -q --no-edit --cleanup=strip >/dev/null 2>&1
        mg_git -C "$WORK/mg_g" commit -q --no-edit --cleanup=strip >/dev/null 2>&1
        if [ "$(mg_state "$WORK/mg_g")" = "$(mg_state "$WORK/mg_o")" ] && [ "$(git -C "$WORK/mg_o" rev-list --parents -1 HEAD | wc -w)" = 3 ]; then note "merge: hand-resolved file, real git commits our merge (same commit id)"; else bad "merge: hand-resolved file committed by git" "$(diff <(mg_state "$WORK/mg_g") <(mg_state "$WORK/mg_o") | head -8)"; fi
    }
    # criss-cross: two merge bases, so a virtual base
    CC='echo 1 >f; printf "a\nb\nc\nd\ne\nf\ng\nh\n" >f; git add -A; git commit -q -m root;
        git checkout -q -b x; printf "a\nX\nc\nd\ne\nf\ng\nh\n" >f; git commit -q -am x1;
        git checkout -q main; printf "a\nb\nc\nd\ne\nf\nY\nh\n" >f; git commit -q -am y1;
        git branch side;
        git merge -q --no-edit x >/dev/null; git checkout -q side; git merge -q --no-edit x2 >/dev/null 2>&1 || true'
    mg_raw "$WORK/mg_src" 'printf "a\nb\nc\nd\ne\nf\ng\nh\n" >f; git add -A; git commit -q -m root;
        git checkout -q -b side; printf "a\nS\nc\nd\ne\nf\ng\nh\n" >f; git commit -q -am s1;
        git checkout -q main; printf "a\nb\nc\nd\ne\nf\nM\nh\n" >f; git commit -q -am m1;
        git branch main1; git checkout -q side; git branch side1;
        git merge -q --no-edit main1; git checkout -q main; git merge -q --no-edit side1;
        printf "a\nS\nc\nd\ne\nf\nM\nh\nmain-last\n" >f; git commit -q -am m2;
        git checkout -q side; printf "a\nS\nc\nd\ne\nf\nM\nh\nside-last\n" >f; git commit -q -am s2; git checkout -q main' &&
    {
        if [ "$(git -C "$WORK/mg_src" merge-base --all main side | wc -l)" = 2 ]; then
            mg_compare "criss-cross: two merge bases give a virtual base (clean prefix, conflicting tail)" "" ""
        else
            bad "merge: criss-cross fixture does not have two merge bases"
        fi
    }
fi

# merge_with_base is what cherry-pick, revert and stash apply call: compare it with `git cherry-pick -n`
mg_apply_case() {
    local label=$1 script=$2
    mg_raw "$WORK/mg_src" "$script" || return 1
    local pick base
    pick=$(git -C "$WORK/mg_src" rev-parse side); base=$(git -C "$WORK/mg_src" rev-parse side~)
    mg_twin "$WORK/mg_src" "$WORK/mg_g"; mg_twin "$WORK/mg_src" "$WORK/mg_o"
    mg_git -C "$WORK/mg_g" cherry-pick -n side >/dev/null 2>&1
    local head oout
    head=$(git -C "$WORK/mg_o" rev-parse HEAD)
    oout=$(mg_ours "$WORK/mg_o/.git" "$WORK/mg_o" apply "$base" "$head" "$pick" "$(git -C "$WORK/mg_o" rev-parse --short "$pick") ($(git -C "$WORK/mg_o" log -1 --format=%s "$pick"))" 2>&1)
    local gi oi gw ow gs os
    gi=$(git -C "$WORK/mg_g" ls-files -s); oi=$(git -C "$WORK/mg_o" ls-files -s)
    gw=$(mg_snap "$WORK/mg_g"); ow=$(mg_snap "$WORK/mg_o")
    gs=$(git -C "$WORK/mg_g" status --porcelain); os=$(git -C "$WORK/mg_o" status --porcelain)
    if [ "$gi" = "$oi" ] && [ "$gw" = "$ow" ] && [ "$gs" = "$os" ]; then
        note "merge_with_base: $label (index, working tree and status equal git cherry-pick -n; ours: $(echo "$oout" | head -1 | cut -c1-60))"
    else
        bad "merge_with_base: $label" "$(diff <(echo "$gi"; echo "$gw"; echo "$gs") <(echo "$oi"; echo "$ow"; echo "$os") | head -12)" "ours: $oout"
    fi
}

if [ -f "$WORK/t_merge" ]; then
    mg_apply_case "clean pick" 'printf "a\nb\nc\nd\ne\nf\ng\nh\n" >f; echo k >k; git add -A; git commit -q -m c1; git checkout -q -b side; printf "A\nb\nc\nd\ne\nf\ng\nh\n" >f; echo new >n; git commit -q -am t; git checkout -q main; printf "a\nb\nc\nd\ne\nf\ng\nH\n" >f; git commit -q -am o'
    mg_apply_case "conflicting pick" 'printf "a\nb\nc\nd\ne\nf\ng\nh\n" >f; echo k >k; git add -A; git commit -q -m c1; git checkout -q -b side; printf "a\nb\nTHEIRS\nd\ne\nf\ng\nh\n" >f; git commit -q -am t; git checkout -q main; printf "a\nb\nOURS\nd\ne\nf\ng\nh\n" >f; git commit -q -am o'
    mg_apply_case "delete in the pick, modify here" 'echo f >f; echo k >k; git add -A; git commit -q -m c1; git checkout -q -b side; git rm -q f; git commit -q -m t; git checkout -q main; echo changed >f; git commit -q -am o'
fi

# mark_resolved and take_side are what the resolution view calls: after the same conflicted
# `git merge`, ours and git's `checkout --ours/--theirs` / `add` / `rm` must leave the same
# index, working tree and status. mg_res_case <label> <build ours> <build theirs> <git cmds> <our args>
mg_res_case() {
    local label=$1 ours=$2 theirs=$3 gcmd=$4 oargs=$5
    mg_build "$WORK/mg_src" merge "printf '$L' >f; echo k >k" "$ours" "$theirs" || return 1
    mg_twin "$WORK/mg_src" "$WORK/mg_g"; mg_twin "$WORK/mg_src" "$WORK/mg_o"
    mg_git -C "$WORK/mg_g" merge --no-edit side >/dev/null 2>&1
    mg_git -C "$WORK/mg_o" merge --no-edit side >/dev/null 2>&1
    (cd "$WORK/mg_g" && eval "$gcmd") >/dev/null 2>&1
    local oout
    oout=$(cd "$WORK/mg_o" && eval "$oargs" 2>&1)
    local gs os
    gs=$(mg_state "$WORK/mg_g"); os=$(mg_state "$WORK/mg_o")
    if [ "$gs" != "$os" ]; then
        bad "merge helpers: $label" "$(diff <(echo "$gs") <(echo "$os") | head -10)" "ours: $oout"
        return 1
    fi
    mg_check_fsck "$WORK/mg_o" "$label" || return 1
    note "merge helpers: $label (index, working tree and status equal git's; ours: $oout)"
}

if [ -f "$WORK/t_merge" ]; then
    L=$'a\nb\nc\nd\ne\nf\ng\nh\n'
    OF="printf 'a\nb\nOURS\nd\ne\nf\ng\nh\n' >f"; TF="printf 'a\nb\nTHEIRS\nd\ne\nf\ng\nh\n' >f"
    T="$WORK/t_merge"; MR="$T .git . resolve f"
    mg_res_case "take ours" "$OF" "$TF" "git checkout --ours f; git add f" "$T .git . take f ours"
    mg_res_case "take theirs" "$OF" "$TF" "git checkout --theirs f; git add f" "$T .git . take f theirs"
    mg_res_case "take the base" "$OF" "$TF" "git show :1:f >f; git add f" "$T .git . take f base"
    mg_res_case "stage a hand-edited file" "$OF" "$TF" "printf 'BOTH\n' >f; git add f" "printf 'BOTH\n' >f; $MR"
    mg_res_case "stage a file deleted by hand" "$OF" "$TF" "rm f; git rm -q f" "rm f; $MR"
    mg_res_case "modify/delete: take the deletion" "echo changed >f" "rm f" "git rm -q f" "$T .git . take f theirs"
    mg_res_case "modify/delete: keep ours" "echo changed >f" "rm f" "git add f" "$T .git . take f ours"
    mg_res_case "delete/modify: take ours (the deletion)" "rm f" "echo changed >f" "git rm -q f" "$T .git . take f ours"
    mg_res_case "delete/modify: take theirs" "rm f" "echo changed >f" "git checkout --theirs f; git add f" "$T .git . take f theirs"
    mg_res_case "add/add: take theirs" "echo ours >n" "echo theirs >n" "git checkout --theirs n; git add n" "$T .git . take n theirs"
    mg_res_case "a mode change survives take ours" "chmod +x f; echo o >>f" "echo t >>f" "git checkout --ours f; git add f" "$T .git . take f ours"
fi

# The merge screens under a real pty (`pty_merge.py`): the merge menu, the banner and the
# "Unmerged paths" section, the resolution view, the editor hand-off, abort, and the
# offer of a merge when a pull cannot fast-forward, each checked against real git.
# It builds its own fixtures under `$WORK/pty_merge`.
if [ -f "$WORK/gitui" ] || bash scripts/build-gitui.sh -o "$WORK/gitui_merge" >"$WORK/gitui_merge_build.log" 2>&1; then
    [ -f "$WORK/gitui" ] && gm_bin="$WORK/gitui" || gm_bin="$WORK/gitui_merge"
    if command -v python3 >/dev/null; then
        if out=$(python3 tests/pty_merge.py "$gm_bin" "$WORK/pty_merge" 2>&1); then
            note "merge pty: $(echo "$out" | grep -c '^ok') merge-screen checks passed under a real pty"
        else
            bad "merge pty" "$out"
        fi
    else
        echo "merge pty: skipped, no python3" >&2
    fi
else
    bad "merge pty: scripts/build-gitui.sh" "$(cat "$WORK/gitui_merge_build.log")"
fi
