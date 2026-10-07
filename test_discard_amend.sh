# Discarding changes (`x`) and amending HEAD (`c`, `A`), each checked against
# what the real git command it stands in for does to an identical copy of the
# same fixture -- `git checkout -- <path>`, `git clean -f -- <path>`,
# `git checkout HEAD -- <path>`, `git rm -f <path>`, `git commit --amend
# --no-edit`. Nothing here compares this program with itself.
#
# Sourced from `test.sh` after `test_gitui.sh`, sharing its shell, `$WORK`,
# `build_tui`, `note`/`bad` and the `pass`/`fail` counters -- `$WORK/
# t_gitclient_ops` is the harness `test_gitui.sh` already built; it is
# rebuilt here only if that step was skipped.
#
# Every fixture is disposable, under `$WORK`, never a real repository.

if [ ! -x "$WORK/t_gitclient_ops" ]; then
    build_tui t_gitclient_ops || true
fi

if [ -x "$WORK/t_gitclient_ops" ]; then
    da_ops="$WORK/t_gitclient_ops"
    da_env="GIT_AUTHOR_NAME=Da_Tester GIT_AUTHOR_EMAIL=da@example.com GIT_COMMITTER_NAME=Da_Tester GIT_COMMITTER_EMAIL=da@example.com"

    # --- the discard fixture -------------------------------------------------
    #
    # One of each shape `discard_path` handles: an unstaged modification
    # (a.txt), an unstaged deletion (keep.txt, gone from disk), a staged
    # modification of a path HEAD has (sub/deep/b.txt), a staged brand-new
    # path (new.txt), an untracked file in a directory of its own
    # (dir/u.txt), and an unstaged change to a symlink (link).
    dafx="$WORK/discard_fixture"
    mkdir -p "$dafx"
    (
        set -e
        cd "$dafx"
        git init -q -b main .
        git config user.email da@example.com
        git config user.name 'Da Tester'
        mkdir -p sub/deep
        printf 'one\n' >a.txt
        printf 'b\n' >sub/deep/b.txt
        printf 'keep\n' >keep.txt
        ln -s a.txt link
        git add -A
        GIT_AUTHOR_DATE='1700000000 +0000' GIT_COMMITTER_DATE='1700000000 +0000' \
            git commit -q -m first
        printf 'one\nchanged\n' >a.txt
        rm keep.txt
        printf 'B\n' >sub/deep/b.txt
        git add sub/deep/b.txt
        printf 'brand new\n' >new.txt
        git add new.txt
        mkdir dir
        printf 'untracked\n' >dir/u.txt
        rm link
        ln -s keep.txt link
    ) >"$WORK/discard_fixture.log" 2>&1 || bad "discard: fixture" "$(tail -5 "$WORK/discard_fixture.log")"

    # `ours` is driven by the client, `want` by real git, from the same start.
    rm -rf "$WORK/discard_want"
    cp -a "$dafx" "$WORK/discard_want"
    dawant="$WORK/discard_want"

    da_compare() {
        local label=$1 path=$2
        local got want
        got=$(git -C "$dafx" status --short)
        want=$(git -C "$dawant" status --short)
        if [ "$got" != "$want" ]; then
            bad "discard: $label (git status --short)" "ours: $got" "git:  $want"
            return
        fi
        if [ -n "$path" ]; then
            if [ -L "$dafx/$path" ] || [ -L "$dawant/$path" ]; then
                got=$(readlink "$dafx/$path" 2>/dev/null || echo "<missing>")
                want=$(readlink "$dawant/$path" 2>/dev/null || echo "<missing>")
            elif [ -e "$dafx/$path" ] || [ -e "$dawant/$path" ]; then
                if ! cmp -s "$dafx/$path" "$dawant/$path"; then
                    bad "discard: $label (file bytes)" "$(diff "$dawant/$path" "$dafx/$path" 2>&1 | head -5)"
                    return
                fi
                got=present
                want=present
            else
                got=absent
                want=absent
            fi
            if [ "$got" != "$want" ]; then
                bad "discard: $label (on-disk shape)" "ours: $got" "git:  $want"
                return
            fi
            got=$(git -C "$dafx" ls-files --stage -- "$path")
            want=$(git -C "$dawant" ls-files --stage -- "$path")
            if [ "$got" != "$want" ]; then
                bad "discard: $label (git ls-files --stage)" "ours: $got" "git:  $want"
                return
            fi
        fi
        note "discard: $label matches real git"
    }

    env $da_env "$da_ops" "$dafx/.git" "$dafx" discard unstaged a.txt >"$WORK/da1.out" 2>&1
    git -C "$dawant" checkout -q -- a.txt
    da_compare "an unstaged modification goes back to the index's blob (git checkout -- path)" a.txt

    env $da_env "$da_ops" "$dafx/.git" "$dafx" discard unstaged keep.txt >"$WORK/da2.out" 2>&1
    git -C "$dawant" checkout -q -- keep.txt
    da_compare "an unstaged deletion is recreated from the index's blob" keep.txt

    env $da_env "$da_ops" "$dafx/.git" "$dafx" discard unstaged link >"$WORK/da3.out" 2>&1
    git -C "$dawant" checkout -q -- link
    da_compare "an unstaged symlink change is restored as a symlink" link

    env $da_env "$da_ops" "$dafx/.git" "$dafx" discard untracked dir/u.txt >"$WORK/da4.out" 2>&1
    git -C "$dawant" clean -q -f -- dir/u.txt
    da_compare "an untracked file is removed (git clean -f -- path)" dir/u.txt
    if [ ! -e "$dafx/dir" ]; then
        note "discard: the directory an untracked file left empty is removed too"
    else
        bad "discard: the directory an untracked file left empty is removed too" "$(ls -la "$dafx/dir")"
    fi

    env $da_env "$da_ops" "$dafx/.git" "$dafx" discard staged sub/deep/b.txt >"$WORK/da5.out" 2>&1
    git -C "$dawant" checkout -q HEAD -- sub/deep/b.txt
    da_compare "a staged modification goes back to HEAD in index and tree (git checkout HEAD -- path)" sub/deep/b.txt

    env $da_env "$da_ops" "$dafx/.git" "$dafx" discard staged new.txt >"$WORK/da6.out" 2>&1
    git -C "$dawant" rm -q -f -- new.txt
    da_compare "a staged new file is dropped from the index and removed (git rm -f path)" new.txt

    # The client's own words for each step, so a wrong branch of discard_path
    # (say, "not in the index") is visible even when the on-disk outcome
    # happened to match.
    if grep -q '^discarded' "$WORK/da1.out" "$WORK/da2.out" "$WORK/da3.out" "$WORK/da4.out" "$WORK/da5.out" "$WORK/da6.out" \
            && ! grep -qv '^discarded' "$WORK/da1.out" "$WORK/da2.out" "$WORK/da3.out" "$WORK/da4.out" "$WORK/da5.out" "$WORK/da6.out"; then
        note "discard: every step reported 'discarded ...', none took a fallback branch"
    else
        bad "discard: every step reported 'discarded ...'" "$(cat "$WORK"/da[1-6].out)"
    fi

    da_fsck=$(git -C "$dafx" fsck --full 2>&1 | grep -v "^dangling blob " || true)
    if [ -z "$da_fsck" ]; then
        note "discard: fsck reports nothing but the expected dangling blobs of discarded content"
    else
        bad "discard: fsck afterward" "$da_fsck"
    fi

    # --- amend ---------------------------------------------------------------
    #
    # `c`, `A`, `f`: HEAD replaced by a commit over the current index with
    # HEAD's own message, parents and author -- `git commit --amend --no-edit`
    # on the copy. Everything but the committer timestamp is compared (both
    # sides are "now", a second apart at most, and git has no flag to pin it
    # that this client also reads).
    amfx="$WORK/amend_fixture"
    mkdir -p "$amfx"
    (
        set -e
        cd "$amfx"
        git init -q -b main .
        git config user.email da@example.com
        git config user.name 'Da Tester'
        printf 'one\n' >a.txt
        git add -A
        GIT_AUTHOR_DATE='1700000000 +0000' GIT_COMMITTER_DATE='1700000000 +0000' \
            git commit -q -m 'root commit'
        printf 'two\n' >b.txt
        git add -A
        GIT_AUTHOR_NAME='Original Author' GIT_AUTHOR_EMAIL='orig@example.com' \
        GIT_AUTHOR_DATE='1700000100 +0530' GIT_COMMITTER_DATE='1700000200 +0000' \
            git commit -q -m 'the commit to amend' -m 'with a body line'
        printf 'three\n' >c.txt
        git add c.txt
    ) >"$WORK/amend_fixture.log" 2>&1 || bad "amend: fixture" "$(tail -5 "$WORK/amend_fixture.log")"
    rm -rf "$WORK/amend_want"
    cp -a "$amfx" "$WORK/amend_want"
    amwant="$WORK/amend_want"
    am_before=$(git -C "$amfx" rev-parse HEAD)

    env $da_env "$da_ops" "$amfx/.git" "$amfx" amend >"$WORK/am1.out" 2>&1
    env $da_env git -C "$amwant" commit -q --amend --no-edit
    am_fmt='%T%n%P%n%an%n%ae%n%ad%n%cn%n%ce%n%B'
    got=$(git -C "$amfx" log -1 --format="$am_fmt")
    want=$(git -C "$amwant" log -1 --format="$am_fmt")
    if [ "$got" = "$want" ] && grep -q '^amended' "$WORK/am1.out"; then
        note "amend: tree, parents, author (name/email/date), committer identity and message all match git commit --amend --no-edit"
    else
        bad "amend: result vs git commit --amend --no-edit" "ours: $got" "git:  $want" "$(cat "$WORK/am1.out")"
    fi
    if [ "$(git -C "$amfx" rev-parse HEAD)" != "$am_before" ] && [ "$(git -C "$amfx" rev-parse HEAD~1)" = "$(git -C "$amwant" rev-parse HEAD~1)" ]; then
        note "amend: HEAD moved, HEAD~1 is the same root both sides -- replaced, not appended"
    else
        bad "amend: HEAD replaced, not appended" "before=$am_before now=$(git -C "$amfx" rev-parse HEAD) root=$(git -C "$amfx" rev-parse HEAD~1 2>&1)"
    fi
    am_status=$(git -C "$amfx" status --short)
    if [ -z "$am_status" ] && [ ! -e "$amfx/.git/COMMIT_EDITMSG" ]; then
        note "amend: nothing left staged and COMMIT_EDITMSG removed afterward"
    else
        bad "amend: clean afterward" "status: $am_status" "$(ls "$amfx/.git/COMMIT_EDITMSG" 2>&1)"
    fi
    am_fsck=$(git -C "$amfx" fsck --full 2>&1 | grep -v '^dangling commit ' || true)
    if [ -z "$am_fsck" ]; then
        note "amend: fsck reports nothing but the expected dangling pre-amend commit"
    else
        bad "amend: fsck afterward" "$am_fsck"
    fi

    # An unborn branch has no HEAD to amend: refused with a message, nothing
    # written.
    unfx="$WORK/amend_unborn"
    mkdir -p "$unfx"
    git -C "$unfx" init -q -b main . >/dev/null 2>&1
    printf 'x\n' >"$unfx/x.txt"
    git -C "$unfx" add x.txt
    env $da_env "$da_ops" "$unfx/.git" "$unfx" amend >"$WORK/am2.out" 2>&1
    if grep -q '^nothing to amend' "$WORK/am2.out" && ! git -C "$unfx" rev-parse -q --verify HEAD >/dev/null 2>&1; then
        note "amend: refused on an unborn branch, nothing committed"
    else
        bad "amend: refused on an unborn branch" "$(cat "$WORK/am2.out")" "$(git -C "$unfx" log --oneline 2>&1)"
    fi
else
    bad "discard/amend: t_gitclient_ops not built, checks skipped"
fi
