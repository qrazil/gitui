# `GIT_checkout.apply_tree_diff` and `GIT_checkout.reset_hard`, against real
# git on identical twin copies of one fixture: `git read-tree -m -u <from>
# <to>` / `git reset --hard` on one, `t_treediff` on the other, and the
# working trees (content, mode, symlinks), `git ls-files -s` and
# `git status --porcelain` compared. Where git refuses, ours must refuse and
# leave worktree and `.git/index` byte-identical to before. Shares `test.sh`'s
# shell, `$WORK`, `$LANGC`, `build`, `note`/`bad` and the counters.

tdx="$WORK/treediff_fx"
rm -rf "$tdx"
mkdir -p "$tdx"
(
    set -e
    cd "$tdx"
    export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
    git init -q -b main .
    git config core.fileMode true
    mkdir -p dir fd/_ df deep/n/m
    rmdir fd/_ 2>/dev/null; rm -rf fd
    echo a1 >a.txt; echo b1 >b.txt; echo '#!/bin/sh' >exec.sh; chmod +x exec.sh
    echo gone >gone.txt; echo x1 >dir/x.txt; echo y1 >dir/y.txt
    echo fdfile >fd; mkdir df; echo inner >df/inner
    ln -s a.txt link; echo same >same.txt; echo last >deep/n/m/last.txt
    echo mo >modeonly.sh; echo keep >keep.txt
    git add -A
    GIT_AUTHOR_DATE='1700000000 +0000' GIT_COMMITTER_DATE='1700000000 +0000' git commit -q -m one
    git branch c1
    echo a2 >a.txt; echo '#!/bin/sh -e' >exec.sh; git rm -q gone.txt; echo x2 >dir/x.txt; echo z >dir/z.txt
    git rm -q -f fd; mkdir fd; echo i >fd/inner
    git rm -q -f df/inner; echo dffile >df
    ln -sf b.txt link; git rm -q -f deep/n/m/last.txt; chmod +x modeonly.sh
    mkdir -p new/sub; echo nw >new/sub/file
    git add -A
    GIT_AUTHOR_DATE='1700000100 +0000' GIT_COMMITTER_DATE='1700000100 +0000' git commit -q -m two
    git branch c2
    git checkout -q c1
) >"$WORK/treediff_fx.log" 2>&1 || bad "treediff fixture" "$(tail -5 "$WORK/treediff_fx.log")"
td_c1=$(git -C "$tdx" rev-parse c1)
td_c2=$(git -C "$tdx" rev-parse c2)
td_t1=$(git -C "$tdx" rev-parse c1^{tree})
td_t2=$(git -C "$tdx" rev-parse c2^{tree})

# what is on disk: path, mode, content (or link target) -- not the stat times
td_snap() {
    (
        cd "$1"
        find . -name .git -prune -o \( -type f -o -type l \) -print | sort | while read -r f; do
            if [ -L "$f" ]; then echo "$f L $(readlink "$f")"; else echo "$f $(stat -c %a "$f") $(sha1sum <"$f")"; fi
        done
    )
}
td_ix() { git -C "$1" ls-files -s; }
td_st() { git -C "$1" status --porcelain; }

# td_case <label> <from> <to> <expect: ok|refuse> <setup function> -- the same
# local state on two copies of the c1 checkout, then git on one and ours on
# the other.
td_case() {
    local label=$1 from=$2 to=$3 expect=$4 setup=$5
    local g="$WORK/td_g" o="$WORK/td_o"
    rm -rf "$g" "$o"
    cp -a "$tdx" "$g"; cp -a "$tdx" "$o"
    if [ "$from" = "$td_t2" ]; then git -C "$g" checkout -q c2; git -C "$o" checkout -q c2; fi
    git -C "$g" update-index -q --refresh; git -C "$o" update-index -q --refresh   # cp -a changed inodes
    $setup "$g"; $setup "$o"
    local before_w before_i
    before_w=$(td_snap "$o" | sha1sum); before_i=$(sha1sum <"$o/.git/index")
    git -C "$g" read-tree -m -u "$from" "$to" >"$WORK/td_git.out" 2>&1
    local grc=$?
    local ours
    ours=$("$WORK/t_treediff" "$o/.git" "$o" apply "$from" "$to" 2>&1)
    if [ "$expect" = ok ]; then
        if [ $grc -ne 0 ]; then bad "treediff: $label" "test expects git to accept, it said: $(head -2 "$WORK/td_git.out")"; return; fi
        case $ours in ok*) ;; *) bad "treediff: $label" "ours: $ours"; return ;; esac
        if [ "$(td_snap "$g")" != "$(td_snap "$o")" ]; then bad "treediff: $label: worktree differs from git" "$(diff <(td_snap "$g") <(td_snap "$o") | head -6)"; return; fi
        if [ "$(td_ix "$g")" != "$(td_ix "$o")" ]; then bad "treediff: $label: index differs from git" "$(diff <(td_ix "$g") <(td_ix "$o") | head -6)"; return; fi
        if [ "$(td_st "$g")" != "$(td_st "$o")" ]; then bad "treediff: $label: status differs from git" "$(diff <(td_st "$g") <(td_st "$o") | head -6)"; return; fi
        note "treediff: $label ($ours; worktree, index and status equal git's)"
    else
        if [ $grc -eq 0 ]; then bad "treediff: $label" "test expects git to refuse but it accepted"; return; fi
        case $ours in refused*) ;; *) bad "treediff: $label" "git refused, ours: $ours"; return ;; esac
        if [ "$(td_snap "$o" | sha1sum)" != "$before_w" ] || [ "$(sha1sum <"$o/.git/index")" != "$before_i" ]; then bad "treediff: $label: refusal wrote something"; return; fi
        note "treediff: $label refused like git, nothing written ($ours)"
    fi
}

td_none() { :; }
td_unrelated() {
    echo "local edit" >>"$1/keep.txt"                 # unstaged, untouched path
    echo "staged" >>"$1/same.txt"; git -C "$1" add same.txt
    echo "untracked" >"$1/scratch.txt"
    mkdir -p "$1/dir"; echo u >"$1/dir/untracked.txt"
}
td_edit_touched() { echo "local" >>"$1/a.txt"; }
td_stage_touched() { echo "staged" >>"$1/a.txt"; git -C "$1" add a.txt; }
td_untracked_in_way() { mkdir -p "$1/new/sub"; echo mine >"$1/new/sub/file"; }
td_untracked_in_dir_to_file() { echo mine >"$1/fd/extra"; }
td_untracked_dir_in_way() { echo mine >"$1/df/untracked"; }
td_deleted_touched() { rm "$1/a.txt"; rm "$1/gone.txt"; }
td_mode_touched() { chmod +x "$1/a.txt"; }
td_index_has_target() { git -C "$1" update-index --cacheinfo "100644,$(git -C "$1" rev-parse c2:a.txt),a.txt"; }
td_unmerged_touched() {
    git -C "$1" rm -q --cached a.txt
    printf '100644 %s 1\ta.txt\n100644 %s 2\ta.txt\n100644 %s 3\ta.txt\n' "$(echo q1 | git -C "$1" hash-object -w --stdin)" "$(echo q2 | git -C "$1" hash-object -w --stdin)" "$(echo q3 | git -C "$1" hash-object -w --stdin)" | git -C "$1" update-index --index-info
}
td_dir_local_file() { echo mine >"$1/deep/n/keepme.txt"; }

if build t_treediff; then
    td_case "clean worktree, c1 to c2" "$td_t1" "$td_t2" ok td_none
    td_case "clean worktree, c2 back to c1 (dir/file swaps, symlink, mode)" "$td_t2" "$td_t1" ok td_none
    td_case "unrelated local edits, staged change and untracked files survive" "$td_t1" "$td_t2" ok td_unrelated
    td_case "a touched file deleted locally is accepted" "$td_t1" "$td_t2" ok td_deleted_touched
    td_case "index already holds the target blob" "$td_t1" "$td_t2" ok td_index_has_target
    td_case "untracked file in a directory that goes away is kept" "$td_t1" "$td_t2" ok td_dir_local_file
    td_case "unstaged edit of a touched file" "$td_t1" "$td_t2" refuse td_edit_touched
    td_case "staged edit of a touched file" "$td_t1" "$td_t2" refuse td_stage_touched
    td_case "executable bit changed on a touched file" "$td_t1" "$td_t2" refuse td_mode_touched
    td_case "untracked file where a new file goes" "$td_t1" "$td_t2" refuse td_untracked_in_way
    td_case "edited tracked file under a directory that goes away" "$td_t2" "$td_t1" refuse td_untracked_in_way
    td_case "untracked file in a directory that becomes a file (backwards)" "$td_t2" "$td_t1" refuse td_untracked_in_dir_to_file
    td_case "untracked file inside a directory that becomes a file" "$td_t1" "$td_t2" refuse td_untracked_dir_in_way
    td_case "unmerged touched path" "$td_t1" "$td_t2" refuse td_unmerged_touched

    # a plain tree id is required: a commit id is a clean error, and the empty
    # tree as `from` writes everything
    out=$("$WORK/t_treediff" "$tdx/.git" "$tdx" apply "$td_c1" "$td_t2" 2>&1)
    case $out in refused*) note "treediff: a commit id as a tree is refused ($out)" ;; *) bad "treediff: commit as tree" "$out" ;; esac
    rm -rf "$WORK/td_e"; mkdir "$WORK/td_e"; git init -q -b main "$WORK/td_e"
    cp -a "$tdx/.git/objects/." "$WORK/td_e/.git/objects/"
    out=$("$WORK/t_treediff" "$WORK/td_e/.git" "$WORK/td_e" apply "" "$td_t2" 2>&1)
    git -C "$WORK/td_e" read-tree "$td_t2" && git -C "$WORK/td_e" read-tree --reset "$td_t2"
    if [ "$(git -C "$WORK/td_e" ls-files -s | sed 's/ [0-9]*\t/ /' | wc -l)" -gt 0 ] && [ "$(td_snap "$WORK/td_e" | wc -l)" = "$(git -C "$WORK/td_e" ls-files | wc -l)" ]; then
        note "treediff: empty tree to a tree writes the whole tree ($out)"
    else
        bad "treediff: from empty" "$out"
    fi
fi

# --- reset_hard --------------------------------------------------------------

# td_reset <label> <target commit> <state function> [detach]
td_reset() {
    local label=$1 target=$2 setup=$3 detach=${4:-}
    local g="$WORK/td_g" o="$WORK/td_o"
    rm -rf "$g" "$o"
    cp -a "$tdx" "$g"; cp -a "$tdx" "$o"
    if [ "$target" = "$td_c1" ]; then git -C "$g" checkout -q c2; git -C "$o" checkout -q c2; fi
    if [ -n "$detach" ]; then git -C "$g" checkout -q --detach; git -C "$o" checkout -q --detach; fi
    git -C "$g" update-index -q --refresh; git -C "$o" update-index -q --refresh
    $setup "$g"; $setup "$o"
    git -C "$g" reset -q --hard "$target"
    local ours
    ours=$("$WORK/t_treediff" "$o/.git" "$o" reset "$target" 2>&1)
    case $ours in ok*) ;; *) bad "reset_hard: $label" "ours: $ours"; return ;; esac
    if [ "$(td_snap "$g")" != "$(td_snap "$o")" ]; then bad "reset_hard: $label: worktree differs from git" "$(diff <(td_snap "$g") <(td_snap "$o") | head -6)"; return; fi
    if [ "$(td_ix "$g")" != "$(td_ix "$o")" ]; then bad "reset_hard: $label: index differs from git" "$(diff <(td_ix "$g") <(td_ix "$o") | head -6)"; return; fi
    if [ "$(td_st "$g")" != "$(td_st "$o")" ]; then bad "reset_hard: $label: status differs from git" "$(diff <(td_st "$g") <(td_st "$o") | head -6)"; return; fi
    if [ "$(git -C "$g" rev-parse HEAD)" != "$(git -C "$o" rev-parse HEAD)" ] || [ "$(git -C "$g" symbolic-ref -q HEAD)" != "$(git -C "$o" symbolic-ref -q HEAD)" ]; then bad "reset_hard: $label: HEAD differs"; return; fi
    local last
    last=$(git -C "$o" reflog -1 HEAD | sed 's/^[0-9a-f]* //')
    case $last in *"reset: moving to $target") ;; *) bad "reset_hard: $label: reflog" "$last"; return ;; esac
    git -C "$o" fsck --strict >"$WORK/td_fsck" 2>&1 || { bad "reset_hard: $label: fsck" "$(head -3 "$WORK/td_fsck")"; return; }
    note "reset_hard: $label ($ours; worktree, index, status, HEAD equal git's; reflog and fsck fine)"
}

td_messy() {
    echo "local" >>"$1/a.txt"; echo "staged" >>"$1/b.txt"; git -C "$1" add b.txt
    rm "$1/exec.sh"; rm -rf "$1/dir"; echo ignored-no >"$1/scratch.txt"
    echo stage >"$1/keep.txt"; git -C "$1" add keep.txt; echo more >>"$1/keep.txt"
    chmod +x "$1/same.txt"
}
td_messy_unmerged() {
    td_messy "$1"
    git -C "$1" rm -q --cached a.txt
    printf '100644 %s 1\ta.txt\n100644 %s 2\ta.txt\n100644 %s 3\ta.txt\n100644 %s 2\textra.txt\n' "$(echo q1 | git -C "$1" hash-object -w --stdin)" "$(echo q2 | git -C "$1" hash-object -w --stdin)" "$(echo q3 | git -C "$1" hash-object -w --stdin)" "$(echo q4 | git -C "$1" hash-object -w --stdin)" | git -C "$1" update-index --index-info
    echo conflict >"$1/extra.txt"
}
td_overwrite_untracked_file() { mkdir -p "$1/dir"; echo mine >"$1/dir/z.txt"; }

if [ -x "$WORK/t_treediff" ]; then
    td_reset "clean, c1 to c2" "$td_c2" td_none
    td_reset "local changes of every kind, c1 to c2" "$td_c2" td_messy
    td_reset "same, backwards to c1 from c2" "$td_c1" td_messy
    td_reset "unmerged entries resolved" "$td_c2" td_messy_unmerged
    td_reset "untracked file at a new path is overwritten" "$td_c2" td_overwrite_untracked_file
    td_reset "detached HEAD moves itself" "$td_c2" td_messy detach
    td_reset "reset to where it already is" "$td_c1" td_none

    # not git's behaviour (it deletes an untracked file standing where a
    # directory must go): this refuses instead, nothing written
    o="$WORK/td_o"; rm -rf "$o"; cp -a "$tdx" "$o"; git -C "$o" update-index -q --refresh
    echo mine >"$o/new"
    w=$(td_snap "$o" | sha1sum); i=$(sha1sum <"$o/.git/index")
    out=$("$WORK/t_treediff" "$o/.git" "$o" reset "$td_c2" 2>&1)
    case $out in refused*) [ "$(td_snap "$o" | sha1sum)" = "$w" ] && [ "$(sha1sum <"$o/.git/index")" = "$i" ] && note "reset_hard: untracked file where a directory must go is refused, nothing written" || bad "reset_hard: refusal wrote" ;; *) bad "reset_hard: untracked file in the way" "$out" ;; esac

    # untracked directory where a file must go: refused, nothing written
    o="$WORK/td_o"; rm -rf "$o"; cp -a "$tdx" "$o"
    rm -f "$o/fd"; mkdir -p "$o/fd/sub"; echo mine >"$o/fd/sub/k"   # c1 tracks file fd; now a dir with an untracked file
    git -C "$o" update-index --force-remove fd
    git -C "$o" update-index --add --cacheinfo "100644,$(git -C "$o" rev-parse c1:fd),fd" 2>/dev/null
    w=$(td_snap "$o" | sha1sum); i=$(sha1sum <"$o/.git/index")
    out=$("$WORK/t_treediff" "$o/.git" "$o" reset "$td_c1" 2>&1)
    case $out in refused*) [ "$(td_snap "$o" | sha1sum)" = "$w" ] && [ "$(sha1sum <"$o/.git/index")" = "$i" ] && note "reset_hard: untracked directory where a file must go is refused, nothing written ($out)" || bad "reset_hard: refusal wrote" ;; *) bad "reset_hard: untracked dir in the way" "$out" ;; esac
fi
git -C "$tdx" fsck --strict >"$WORK/td_fsck_fx" 2>&1 && note "treediff: fixture fsck --strict clean" || bad "treediff: fixture fsck" "$(head -3 "$WORK/td_fsck_fx")"
