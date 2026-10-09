# `GIT_stash.m31` and `GIT_udiff.m31` against real git: the stash commits, the
# reflog stack, `list`, `show -p`, `apply`/`pop` (with and without `--index`),
# `drop` and `branch`, in both directions -- git pops what we pushed, we pop what
# git pushed. Every fixture is a pair of identical copies: git does the operation
# on one, `t_stash` on the other, and the two must end in the same state.
# Sourced from `test.sh`: shares `$WORK`, `$LANGC`, `build`, `note`/`bad`.

stx="$WORK/stash_fx"
mkdir -p "$stx"
st_env() { env GIT_AUTHOR_NAME=Stash_Tester GIT_AUTHOR_EMAIL=stash@example.com GIT_COMMITTER_NAME=Stash_Tester GIT_COMMITTER_EMAIL=stash@example.com GIT_AUTHOR_DATE='1700000000 +0000' GIT_COMMITTER_DATE='1700000000 +0000' "$@"; }
st_git() { local d=$1; shift; st_env git -C "$d" "$@"; }
st_ours() { local d=$1; shift; st_env "$WORK/t_stash" "$d/.git" "$d" "$@"; }

# the interesting fixture: staged and unstaged edits to one file, a mode change,
# a staged add, a staged and an unstaged delete, a missing final newline,
# untracked files in and out of a directory
st_fixture() {
    local d=$1
    rm -rf "$d"
    git init -q -b main "$d"
    (
        set -e
        cd "$d"
        export GIT_AUTHOR_NAME=Stash_Tester GIT_AUTHOR_EMAIL=stash@example.com GIT_COMMITTER_NAME=Stash_Tester GIT_COMMITTER_EMAIL=stash@example.com
        export GIT_AUTHOR_DATE='1700000000 +0000' GIT_COMMITTER_DATE='1700000000 +0000'
        mkdir dir
        printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n' >a.txt
        printf 'bee\n' >b.txt
        printf 'see\n' >dir/c.txt
        printf '#!/bin/sh\n' >run.sh; chmod 755 run.sh
        printf 'gone\n' >del.txt
        printf 'staged-gone\n' >del2.txt
        printf 'no newline' >nonl.txt
        git add .; git commit -q -m 'base commit: with a colon'
        printf 'second\n' >>b.txt; git add b.txt; git commit -q -m 'second'
        sed -i 's/^two$/TWO/' a.txt; git add a.txt
        sed -i 's/^nine$/NINE/' a.txt
        printf 'bee\nsecond\nthird\n' >b.txt
        rm dir/c.txt
        chmod 644 run.sh
        git rm -q del2.txt
        rm del.txt
        printf 'brand new\n' >new.txt; git add new.txt
        printf 'no newline, changed' >nonl.txt
        printf 'untracked\n' >u.txt
        printf 'untracked too\n' >dir/u2.txt
    )
}

# everything observable about a repository, for comparing two of them
st_state() {
    local d=$1
    echo "HEAD $(git -C "$d" rev-parse HEAD) $(git -C "$d" symbolic-ref -q HEAD)"
    echo "STASH $(git -C "$d" rev-parse -q --verify refs/stash)"
    git -C "$d" status --porcelain=v1 -uall
    git -C "$d" ls-files -s
    git -C "$d" stash list
    (cd "$d" && find . -path ./.git -prune -o -type f -printf '%m %p\n' | LC_ALL=C sort | while read -r mode p; do echo "$mode $p $(sha1sum <"$p" | cut -c1-12)"; done)
    cat "$d/.git/logs/refs/stash" 2>/dev/null
}

# diff two repositories' state; prints nothing when equal
st_same() { diff <(st_state "$1") <(st_state "$2") | head -${3:-12}; }

st_fsck() { local out; out=$(git -C "$1" fsck --strict 2>&1) && ! grep -q '^error' <<<"$out"; }

st_check() {  # st_check <label> <repo-a> <repo-b>
    local d; d=$(st_same "$2" "$3")
    if [ -z "$d" ]; then note "stash: $1"; else bad "stash: $1" "$d"; fi
}

if build t_stash; then
    st_fixture "$stx/base" >"$WORK/stash_fx.log" 2>&1 || bad "stash: fixture" "$(tail -5 "$WORK/stash_fx.log")"

    # copy the base fixture to $stx/<name>-git and $stx/<name>-ours
    st_pair() { rm -rf "$stx/$1-git" "$stx/$1-ours"; cp -a "$stx/base" "$stx/$1-git"; cp -a "$stx/base" "$stx/$1-ours"; }

    # --- push: the commits, the ref, the log, the cleaned tree ---------------------
    for variant in "plain:" "untracked:-u" "keep:-k" "keep-untracked:-u -k" "message:-m a_message" "message-u:-u -m with_untracked"; do
        name=${variant%%:*}; flags=${variant#*:}
        st_pair "push-$name"
        g="$stx/push-$name-git"; o="$stx/push-$name-ours"
        st_git "$g" stash push -q $flags >/dev/null 2>&1
        want=$(git -C "$g" rev-parse refs/stash)
        got=$(st_ours "$o" push $flags 2>&1)
        if [ "$got" = "$want" ]; then note "stash push $flags: commit $want identical to git's"; else bad "stash push $flags: commit id" "git $want" "ours $got"; fi
        for rev in refs/stash^2 refs/stash^1; do
            [ "$(git -C "$g" rev-parse $rev)" = "$(git -C "$o" rev-parse $rev 2>&1)" ] || bad "stash push $flags: $rev differs"
        done
        [ "$(git -C "$g" rev-parse -q --verify 'refs/stash^3' 2>/dev/null)" = "$(git -C "$o" rev-parse -q --verify 'refs/stash^3' 2>/dev/null)" ] || bad "stash push $flags: untracked parent differs"
        st_check "push $flags leaves the same index, worktree, list and reflog" "$g" "$o"
        st_fsck "$o" && note "stash push $flags: fsck --strict clean" || bad "stash push $flags: fsck" "$(git -C "$o" fsck --strict 2>&1 | head -5)"
        w=$(git -C "$g" show -s --format=%B refs/stash | od -c | md5sum); w2=$(git -C "$o" show -s --format=%B refs/stash | od -c | md5sum)
        [ "$w" = "$w2" ] || bad "stash push $flags: message bytes differ"
    done

    # `git stash create` makes the same W commit without touching anything
    st_pair create
    want=$(st_git "$stx/create-git" stash create)
    got=$(st_ours "$stx/create-ours" push 2>&1)
    [ "$want" = "$got" ] && note "stash push: commit identical to git stash create" || bad "stash push vs create" "git $want" "ours $got"

    # a detached HEAD says "(no branch)"
    st_pair detached
    for r in git ours; do st_git "$stx/detached-$r" checkout -q --detach; done
    st_git "$stx/detached-git" stash push -q -u >/dev/null 2>&1
    got=$(st_ours "$stx/detached-ours" push -u 2>&1)
    [ "$got" = "$(git -C "$stx/detached-git" rev-parse refs/stash)" ] && note "stash push on a detached HEAD: commit identical to git's" || bad "stash push, detached HEAD" "$got"

    # nothing to stash
    st_pair clean
    st_git "$stx/clean-git" stash push -q -u >/dev/null 2>&1
    st_git "$stx/clean-git" checkout -q -- . 2>/dev/null
    out=$(st_ours "$stx/clean-ours" push -u 2>&1)
    out=$(st_ours "$stx/clean-ours" push -u 2>&1); rc=$?
    [ $rc -ne 0 ] && grep -qi "no local changes" <<<"$out" && note "stash push: nothing to save is refused" || bad "stash push: nothing to save" "rc=$rc $out"

    # --- list / show -p ------------------------------------------------------------
    st_pair show
    for m in one two three; do
        st_git "$stx/show-git" stash push -q -u -m "stash $m" >/dev/null 2>&1
        printf '%s\n' "$m" >>"$stx/show-git/a.txt"; printf '%s\n' "$m" >"$stx/show-git/new-$m.txt"
    done
    st_git "$stx/show-git" stash push -q -u -m last >/dev/null 2>&1
    got=$(st_ours "$stx/show-git" list)
    want=$(st_git "$stx/show-git" stash list)
    [ "$got" = "$want" ] && note "stash list: $(wc -l <<<"$want") entries match git stash list" || bad "stash list" "$(diff <(echo "$want") <(echo "$got"))"
    for n in 0 1 2 3; do
        st_git "$stx/show-git" stash show -p --no-color "stash@{$n}" >"$WORK/show.want" 2>&1
        st_ours "$stx/show-git" show $n >"$WORK/show.got" 2>&1
        if cmp -s "$WORK/show.want" "$WORK/show.got"; then note "stash show -p stash@{$n}: $(wc -c <"$WORK/show.want") bytes identical to git"; else bad "stash show -p stash@{$n}" "$(diff "$WORK/show.want" "$WORK/show.got" | head -8)"; fi
    done
    # with the untracked files too
    st_pair showu
    st_git "$stx/showu-git" stash push -q -u >/dev/null 2>&1
    st_git "$stx/showu-git" stash show -p -u --no-color >"$WORK/show.want" 2>&1
    st_ours "$stx/showu-git" show 0 -u >"$WORK/show.got" 2>&1
    if cmp -s "$WORK/show.want" "$WORK/show.got"; then note "stash show -p --include-untracked: identical to git"; else bad "stash show -p -u" "$(diff "$WORK/show.want" "$WORK/show.got" | head -8)"; fi

    # --- apply and pop, both directions -----------------------------------------
    for variant in "plain:" "untracked:-u" "keep:-k" "message:-m x"; do
        name=${variant%%:*}; flags=${variant#*:}
        for cmd in apply pop; do
            for idx in "" "--index"; do
                tag="$name-$cmd${idx:+-index}"
                st_pair "t-$tag"; st_pair "u-$tag"
                # (1) we pushed, git applies/pops   vs   git pushed, git applies/pops
                st_git "$stx/t-$tag-git" stash push -q $flags >/dev/null 2>&1
                st_ours "$stx/t-$tag-ours" push $flags >/dev/null 2>&1
                st_git "$stx/t-$tag-git" stash $cmd -q $idx >/dev/null 2>&1; r1=$?
                st_git "$stx/t-$tag-ours" stash $cmd -q $idx >/dev/null 2>&1; r2=$?
                if [ $r1 -eq $r2 ]; then st_check "git $cmd $idx of our stash ($name) = of git's" "$stx/t-$tag-git" "$stx/t-$tag-ours"; else bad "git $cmd $idx of our stash ($name): exit $r2, git's own $r1"; fi
                # (2) git pushed, we apply/pop   vs   git pushed, git applies/pops
                st_git "$stx/u-$tag-git" stash push -q $flags >/dev/null 2>&1
                st_git "$stx/u-$tag-ours" stash push -q $flags >/dev/null 2>&1
                st_git "$stx/u-$tag-git" stash $cmd -q $idx >/dev/null 2>&1; r1=$?
                pre=$(st_state "$stx/u-$tag-ours")
                out=$(st_ours "$stx/u-$tag-ours" $cmd $idx 0 2>&1); r2=$?
                if [ "$name" = keep ] && [ $r1 -eq 0 ] && [ $r2 -ne 0 ] && grep -q "needs a merge" <<<"$out"; then
                    # the index kept by -k already holds part of the stash: git merges, we say so
                    [ "$pre" = "$(st_state "$stx/u-$tag-ours")" ] && note "our $cmd $idx of git's -k stash: reports 'needs a merge' (the merge hook), changes nothing" || bad "our $cmd $idx of git's -k stash changed something while refusing"
                elif [ $r1 -ne 0 ] || [ $r2 -ne 0 ]; then bad "$cmd $idx of git's stash ($name)" "git rc=$r1 ours rc=$r2 $out"; else
                    st_check "our $cmd $idx of git's stash ($name) = git's" "$stx/u-$tag-git" "$stx/u-$tag-ours"
                    st_fsck "$stx/u-$tag-ours" || bad "fsck after our $cmd $idx ($name)"
                fi
            done
        done
    done

    # --- refusing --------------------------------------------------------------------
    st_pair dirty
    st_git "$stx/dirty-git" stash push -q >/dev/null 2>&1
    st_git "$stx/dirty-ours" stash push -q >/dev/null 2>&1
    for r in git ours; do printf 'local edit\n' >>"$stx/dirty-$r/a.txt"; done
    st_git "$stx/dirty-git" stash apply -q >/dev/null 2>&1; r1=$?
    out=$(st_ours "$stx/dirty-ours" apply 0 2>&1); r2=$?
    if [ $r1 -ne 0 ] && [ $r2 -ne 0 ]; then st_check "apply over conflicting local changes is refused and changes nothing" "$stx/dirty-git" "$stx/dirty-ours"; else bad "apply over local changes" "git rc=$r1 ours rc=$r2 $out"; fi
    out=$(st_ours "$stx/dirty-ours" pop 0 2>&1); r2=$?
    [ $r2 -ne 0 ] && [ "$(git -C "$stx/dirty-ours" stash list | wc -l)" = 1 ] && note "stash pop: a refused pop keeps the stash" || bad "stash pop refused keeps stash" "rc=$r2 $out"

    # an untracked file in the way of an untracked file of the stash
    st_pair collide
    st_git "$stx/collide-ours" stash push -q -u >/dev/null 2>&1
    printf 'in the way\n' >"$stx/collide-ours/u.txt"
    out=$(st_ours "$stx/collide-ours" apply 0 2>&1); r2=$?
    [ $r2 -ne 0 ] && [ "$(cat "$stx/collide-ours/u.txt")" = "in the way" ] && note "stash apply: an untracked file in the way is refused untouched" || bad "stash apply untracked collision" "rc=$r2 $out"

    # HEAD moved, other files: git merges; we apply where the paths are disjoint
    st_pair moved
    for r in git ours; do
        st_git "$stx/moved-$r" stash push -q >/dev/null 2>&1
        printf 'head moved\n' >"$stx/moved-$r/h.txt"; st_git "$stx/moved-$r" add h.txt; st_git "$stx/moved-$r" commit -q -m 'other file' >/dev/null
    done
    st_git "$stx/moved-git" stash apply -q >/dev/null 2>&1; r1=$?
    out=$(st_ours "$stx/moved-ours" apply 0 2>&1); r2=$?
    if [ $r1 -eq 0 ] && [ $r2 -eq 0 ]; then
        # git's merge leaves the staged state differently (new files staged only); compare the files
        if diff <(cd "$stx/moved-git" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha1sum) <(cd "$stx/moved-ours" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha1sum) >/dev/null; then note "stash apply after HEAD moved (disjoint paths): worktree equals git's"; else bad "stash apply, HEAD moved: worktree differs"; fi
        st_fsck "$stx/moved-ours" && note "stash apply, HEAD moved: fsck clean" || bad "stash apply, HEAD moved: fsck"
    else bad "stash apply after HEAD moved" "git rc=$r1 ours rc=$r2 $out"; fi

    # HEAD moved on a file the stash also changed: a real three-way merge, as git does it.
    # Each case: both copies get the same stash (made by git) and the same new HEAD commit;
    # git applies/pops on one, we do on the other; state, AUTO_MERGE, exit status and the
    # kept (or dropped) stash must be the same.
    st_head_clean() { sed -i 's/^eight$/EIGHT/' a.txt; git add a.txt; git commit -q -m 'head: clean hunk'; }
    st_head_conflict() { sed -i 's/^two$/deux/' a.txt; git add a.txt; git commit -q -m 'head: conflicting hunk'; }
    st_head_many() {
        sed -i 's/^two$/deux/' a.txt; printf 'head-b\n' >>b.txt; printf 'head edit\n' >del.txt
        git rm -q dir/c.txt; printf 'head new\n' >new.txt; chmod 755 nonl.txt; git add -A; git commit -q -m 'head: many'
    }
    st_head_mode() { chmod 755 b.txt; printf 'head-b\n' >>b.txt; git add b.txt; git commit -q -m 'head: mode and append'; }
    st_head_deleted() { git rm -q b.txt; git commit -q -m 'head: deletes the file the stash edited'; }
    st_head_staged() { sed -i 's/^eight$/EIGHT/' a.txt; git add a.txt; }
    for variant in "clean:plain:" "conflict:plain:" "many:plain:" "mode:plain:" "deleted:plain:" "conflict:untracked:-u" "many:untracked:-u" "clean:keep:-k" "staged:plain:"; do
        scen=${variant%%:*}; rest=${variant#*:}; name=${rest%%:*}; flags=${rest#*:}
        for cmd in apply pop; do
            for idx in "" "--index"; do
                tag="mg-$scen-$name-$cmd${idx:+-index}"
                st_pair "$tag"
                for r in git ours; do
                    st_git "$stx/$tag-$r" stash push -q $flags >/dev/null 2>&1
                    (cd "$stx/$tag-$r" && st_env bash -c "$(declare -f st_head_$scen); st_head_$scen") >/dev/null 2>&1
                done
                st_git "$stx/$tag-git" stash $cmd -q $idx >"$WORK/mg.git.out" 2>&1; r1=$?
                pre=$(st_state "$stx/$tag-ours")
                out=$(st_ours "$stx/$tag-ours" $cmd $idx 0 2>&1); r2=$?
                if { [ $r1 -eq 0 ] && [ $r2 -ne 0 ]; } || { [ $r1 -ne 0 ] && [ $r2 -eq 0 ]; }; then
                    bad "stash $cmd $idx after $scen head move ($name)" "git rc=$r1 ours rc=$r2 $out"
                    continue
                fi
                if [ -n "$idx" ] && [ $r1 -ne 0 ] && [ $r2 -ne 0 ] && grep -q 'would be overwritten by merge' "$WORK/mg.git.out"; then
                    # git fails half way here (index reset, files not); we refuse before writing anything
                    [ "$pre" = "$(st_state "$stx/$tag-ours")" ] && note "stash $cmd $idx after $scen head move ($name): refused, nothing written (git fails half way)" || bad "stash $cmd $idx after $scen head move ($name): wrote something while refusing"
                    continue
                fi
                st_check "stash $cmd $idx after $scen head move ($name): state equals git's (rc $r1)" "$stx/$tag-git" "$stx/$tag-ours"
                if [ -e "$stx/$tag-git/.git/AUTO_MERGE" ]; then
                    [ "$(cat "$stx/$tag-git/.git/AUTO_MERGE" 2>/dev/null)" = "$(cat "$stx/$tag-ours/.git/AUTO_MERGE" 2>/dev/null)" ] || bad "stash $cmd $idx after $scen head move ($name): AUTO_MERGE differs"
                fi
                if [ $r1 -ne 0 ]; then
                    [ "$(git -C "$stx/$tag-ours" stash list | wc -l)" = "$(git -C "$stx/$tag-git" stash list | wc -l)" ] || bad "stash $cmd ($scen/$name): stash list differs after the failed $cmd"
                    diff <(cd "$stx/$tag-git" && grep -rn '^[<=>]\{7\}' --include='*.txt' . | cut -d: -f1,3-) <(cd "$stx/$tag-ours" && grep -rn '^[<=>]\{7\}' --include='*.txt' . | cut -d: -f1,3-) >/dev/null || bad "stash $cmd ($scen/$name): conflict markers differ"
                fi
                st_fsck "$stx/$tag-ours" || bad "fsck after our $cmd $idx ($scen/$name)"
            done
        done
    done

    # a conflicted pop keeps the stash, and git can finish what we started
    st_pair mgfin
    for r in git ours; do
        st_git "$stx/mgfin-$r" stash push -q >/dev/null 2>&1
        (cd "$stx/mgfin-$r" && st_env bash -c "$(declare -f st_head_conflict); st_head_conflict") >/dev/null 2>&1
    done
    st_ours "$stx/mgfin-ours" pop 0 >/dev/null 2>&1
    [ "$(git -C "$stx/mgfin-ours" stash list | wc -l)" = 1 ] && note "stash pop: a conflicted pop keeps the stash" || bad "stash pop conflicted: stash dropped"
    for r in git ours; do
        printf 'resolved\n' >"$stx/mgfin-$r/a.txt"; st_git "$stx/mgfin-$r" add a.txt
    done
    st_git "$stx/mgfin-ours" stash drop -q >/dev/null 2>&1
    git -C "$stx/mgfin-ours" ls-files -u | grep -q . && bad "stash pop conflict: add did not clear the unmerged entries" || note "stash pop conflict: git add resolves what we left; git stash drop drops the kept stash"
    st_fsck "$stx/mgfin-ours" && note "stash pop conflict: fsck clean after resolving" || bad "stash pop conflict: fsck"

    # --- drop: the reflog stack as git rewrites it ------------------------------------
    st_pair drop
    for r in git ours; do
        for m in a b c d; do
            printf '%s\n' "$m" >>"$stx/drop-$r/b.txt"
            st_env git -C "$stx/drop-$r" stash push -q -m "stash $m" >/dev/null 2>&1
        done
    done
    st_check "four pushes build the same stack" "$stx/drop-git" "$stx/drop-ours"
    for n in 1 0 1 0; do
        st_git "$stx/drop-git" stash drop -q "stash@{$n}" >/dev/null 2>&1
        out=$(st_ours "$stx/drop-ours" drop $n 2>&1)
        st_check "drop stash@{$n} leaves git's stack" "$stx/drop-git" "$stx/drop-ours"
    done
    [ ! -e "$stx/drop-ours/.git/refs/stash" ] && [ ! -e "$stx/drop-ours/.git/logs/refs/stash" ] && note "stash drop: the last drop removes refs/stash and its log" || bad "stash drop of the last stash leaves files"
    out=$(st_ours "$stx/drop-ours" drop 0 2>&1); [ $? -ne 0 ] && note "stash drop: no stash is an error" || bad "stash drop on empty"

    # --- branch ------------------------------------------------------------------------
    st_pair branch
    for r in git ours; do
        st_git "$stx/branch-$r" stash push -q -u >/dev/null 2>&1
        printf 'later\n' >"$stx/branch-$r/h.txt"; st_git "$stx/branch-$r" add h.txt; st_git "$stx/branch-$r" commit -q -m later >/dev/null
    done
    st_git "$stx/branch-git" stash branch topic >/dev/null 2>&1; r1=$?
    out=$(st_ours "$stx/branch-ours" branch topic 0 2>&1); r2=$?
    if [ $r1 -eq 0 ] && [ $r2 -eq 0 ]; then
        st_check "stash branch: branch, HEAD, index, worktree and stack equal git's" "$stx/branch-git" "$stx/branch-ours"
        git -C "$stx/branch-ours" reflog show --format=%gs HEAD | grep -qx 'checkout: moving from main to topic' && note "stash branch: the HEAD reflog has git's checkout line" || bad "stash branch: HEAD reflog" "$(git -C "$stx/branch-ours" reflog show --format=%gs HEAD | head -3)"
        st_fsck "$stx/branch-ours" || bad "stash branch: fsck"
    else bad "stash branch" "git rc=$r1 ours rc=$r2 $out"; fi
    out=$(st_ours "$stx/branch-ours" branch topic 0 2>&1); [ $? -ne 0 ] && note "stash branch: an existing branch name is refused" || bad "stash branch: existing name"
fi

# --- the stash UI under a pty (z menu, Stashes section, list overlay) -----------------
if [ ! -x "$WORK/gitui" ]; then
    bash scripts/build-gitui.sh -o "$WORK/gitui" >"$WORK/stash_build.log" 2>&1 \
        || bad "stash ui: scripts/build-gitui.sh" "$(cat "$WORK/stash_build.log")"
fi
if [ -x "$WORK/gitui" ] && command -v python3 >/dev/null; then
    if out=$(python3 tests/pty_stash.py "$WORK/gitui" "$WORK/ptystash" 2>&1); then
        note "gitui stash pty: $(echo "$out" | grep -c '^ok') checks agree with git stash"
    else
        bad "gitui stash pty" "$(echo "$out" | grep -v '^ok' | head -30)"
    fi
fi
