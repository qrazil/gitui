# `checkout.m31` -- branch listing, working-tree checkout, branch creation --
# driven through `t_checkout` and checked against real git as the oracle.
# Shares `test.sh`'s shell, `$WORK`, `$LANGC`, `build`, `note`/`bad` and the
# pass/fail counters, the way `test_write.sh` does.

cofx="$WORK/checkout_fx"
mkdir -p "$cofx"
(
    set -e
    cd "$cofx"
    git init -q -b main .
    git config user.email o@example.com
    git config user.name 'Checkout Tester'
    export GIT_AUTHOR_DATE='1700000000 +0000' GIT_COMMITTER_DATE='1700000000 +0000'
    printf 'one\n' >a.txt
    printf 'keep\n' >keep.txt
    mkdir sub
    printf 'deep\n' >sub/d.txt
    printf '#!/bin/sh\necho hi\n' >run.sh
    chmod +x run.sh
    git add -A
    git commit -q -m first
    git checkout -q -b feature
    printf 'two\n' >a.txt
    printf 'added\n' >added.txt
    mkdir -p new/nested/dir
    printf 'n\n' >new/nested/dir/n.txt
    git rm -q sub/d.txt
    printf '#!/bin/sh\necho changed\n' >run.sh
    chmod -x run.sh
    ln -s a.txt link
    git add -A
    git commit -q -m second
    git checkout -q main
) >"$WORK/checkout_fx.log" 2>&1 || bad "checkout: fixture" "$(tail -5 "$WORK/checkout_fx.log")"

# every file git knows at HEAD must hold exactly git's bytes, the index must
# match what a real `git checkout` would have written, and fsck must be quiet
co_verify() {
    local dir=$1 label=$2 want_head=$3 ok=1 msg=""
    local got
    got=$(cd "$dir" && git status --short)
    [ -z "$got" ] || { ok=0; msg="$msg status not clean: $got;"; }
    got=$(cd "$dir" && { git symbolic-ref -q HEAD || git rev-parse HEAD; })
    [ "$got" = "$want_head" ] || { ok=0; msg="$msg HEAD=$got want $want_head;"; }
    local path
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if [ -L "$dir/$path" ]; then
            [ "$(readlink "$dir/$path")" = "$(cd "$dir" && git show "HEAD:$path")" ] || { ok=0; msg="$msg symlink $path;"; }
        else
            cmp -s "$dir/$path" <(cd "$dir" && git show "HEAD:$path") || { ok=0; msg="$msg bytes $path;"; }
        fi
    done < <(cd "$dir" && git ls-tree -r --name-only HEAD)
    got=$(cd "$dir" && git fsck --no-dangling 2>&1)
    [ -z "$got" ] || { ok=0; msg="$msg fsck: $got;"; }
    if [ $ok = 1 ]; then note "checkout: $label"; else bad "checkout: $label" "$msg"; fi
}

if build t_checkout; then
    gd="$cofx/.git"
    out=$("$WORK/t_checkout" "$gd" "$cofx" branches 2>&1)
    want=$(printf '* main %s\n- feature %s' "$(git -C "$cofx" rev-parse main)" "$(git -C "$cofx" rev-parse feature)")
    if [ "$(printf '%s\n' "$out" | sort)" = "$(printf '%s\n' "$want" | sort)" ]; then
        note "checkout: branch list, current marked"
    else
        bad "checkout: branch list" "$out" "want: $want"
    fi

    # main -> feature: adds, modifies, deletes (with dir pruning), exec bit, symlink
    out=$("$WORK/t_checkout" "$gd" "$cofx" checkout feature 2>&1)
    case "$out" in "ok written="*) note "checkout: main -> feature reports ok";; *) bad "checkout: main -> feature" "$out";; esac
    co_verify "$cofx" "main -> feature leaves tree == git's, status clean" refs/heads/feature
    [ ! -e "$cofx/sub" ] && note "checkout: emptied directory pruned" || bad "checkout: emptied directory pruned" "sub still exists"
    [ ! -x "$cofx/run.sh" ] && note "checkout: exec bit cleared" || bad "checkout: exec bit cleared" "run.sh executable"
    # index must be byte-identical to a fresh `git read-tree` of the same commit
    (cd "$cofx" && git ls-files --stage) >"$WORK/co_idx_a.txt"
    rm -f "$WORK/co_index_ref"
    (cd "$cofx" && GIT_INDEX_FILE="$WORK/co_index_ref" git read-tree HEAD && GIT_INDEX_FILE="$WORK/co_index_ref" git ls-files --stage >"$WORK/co_idx_b.txt")
    cmp -s "$WORK/co_idx_a.txt" "$WORK/co_idx_b.txt" && note "checkout: index entries identical to git read-tree" || bad "checkout: index entries" "$(diff "$WORK/co_idx_a.txt" "$WORK/co_idx_b.txt" | head -5)"

    # back again
    out=$("$WORK/t_checkout" "$gd" "$cofx" checkout main 2>&1)
    case "$out" in "ok written="*) note "checkout: feature -> main reports ok";; *) bad "checkout: feature -> main" "$out";; esac
    co_verify "$cofx" "feature -> main leaves tree == git's, status clean" refs/heads/main
    [ -x "$cofx/run.sh" ] && [ -f "$cofx/sub/d.txt" ] && [ ! -e "$cofx/link" ] && [ ! -e "$cofx/new" ] \
        && note "checkout: restored exec bit, deleted file back, added paths gone" \
        || bad "checkout: round trip on-disk shape" "$(ls -la "$cofx")"

    # detached
    first=$(git -C "$cofx" rev-parse main)
    out=$("$WORK/t_checkout" "$gd" "$cofx" checkout feature 2>&1 >/dev/null; "$WORK/t_checkout" "$gd" "$cofx" detach "$first" 2>&1)
    case "$out" in "ok written="*) note "checkout: detach reports ok";; *) bad "checkout: detach" "$out";; esac
    co_verify "$cofx" "detached HEAD at a commit id, tree == git's" "$first"

    # refusal: dirty tracked file on a differing path
    "$WORK/t_checkout" "$gd" "$cofx" checkout main >/dev/null 2>&1
    printf 'local edit\n' >>"$cofx/a.txt"
    before=$(cd "$cofx" && git status --short; git rev-parse HEAD; cat a.txt)
    out=$("$WORK/t_checkout" "$gd" "$cofx" checkout feature 2>&1); rc=$?
    after=$(cd "$cofx" && git status --short; git rev-parse HEAD; cat a.txt)
    if [ $rc -eq 1 ] && case "$out" in refused:*) true;; *) false;; esac && [ "$before" = "$after" ] && [ ! -e "$cofx/added.txt" ]; then
        note "checkout: dirty tracked file refused, nothing written ($out)"
    else
        bad "checkout: dirty refusal" "rc=$rc out=$out" "$(diff <(echo "$before") <(echo "$after"))"
    fi
    # a dirty file on a path both branches share is NOT in the way
    (cd "$cofx" && git checkout -q a.txt && printf 'tweak\n' >>keep.txt)
    out=$("$WORK/t_checkout" "$gd" "$cofx" checkout feature 2>&1)
    if case "$out" in "ok"*) true;; *) false;; esac && [ "$(cat "$cofx/keep.txt")" = "$(printf 'keep\ntweak')" ] || [ "$(cat "$cofx/keep.txt")" = "$(printf 'keep\ntweak\n')" ]; then
        note "checkout: local edit to a shared path survives the switch"
    else
        bad "checkout: shared-path edit survives" "$out" "$(cat "$cofx/keep.txt")"
    fi
    (cd "$cofx" && git checkout -q -- keep.txt)
    "$WORK/t_checkout" "$gd" "$cofx" checkout main >/dev/null 2>&1

    # refusal: untracked collision
    printf 'mine\n' >"$cofx/added.txt"
    before=$(cd "$cofx" && git status --short; git rev-parse HEAD; cat added.txt)
    out=$("$WORK/t_checkout" "$gd" "$cofx" checkout feature 2>&1); rc=$?
    after=$(cd "$cofx" && git status --short; git rev-parse HEAD; cat added.txt)
    if [ $rc -eq 1 ] && case "$out" in refused:*) true;; *) false;; esac && [ "$before" = "$after" ]; then
        note "checkout: untracked collision refused, nothing written ($out)"
    else
        bad "checkout: untracked collision refusal" "rc=$rc out=$out" "$(diff <(echo "$before") <(echo "$after"))"
    fi
    rm -f "$cofx/added.txt"

    # new branch
    out=$("$WORK/t_checkout" "$gd" "$cofx" new topic 2>&1)
    if [ "$out" = "ok" ] && [ "$(git -C "$cofx" symbolic-ref HEAD)" = refs/heads/topic ] \
        && [ "$(git -C "$cofx" rev-parse topic)" = "$(git -C "$cofx" rev-parse main)" ] && [ -z "$(git -C "$cofx" status --short)" ]; then
        note "checkout: new branch at HEAD, HEAD moved onto it"
    else
        bad "checkout: new branch" "$out" "$(git -C "$cofx" symbolic-ref HEAD)"
    fi
    out=$("$WORK/t_checkout" "$gd" "$cofx" new topic 2>&1); rc=$?
    [ $rc -eq 1 ] && note "checkout: existing branch name refused ($out)" || bad "checkout: duplicate name" "rc=$rc $out"
    out=$("$WORK/t_checkout" "$gd" "$cofx" new 'bad name' 2>&1); rc=$?
    [ $rc -eq 1 ] && note "checkout: invalid branch name refused ($out)" || bad "checkout: invalid name" "rc=$rc $out"
    (cd "$cofx" && git fsck --no-dangling 2>&1 | head -3) | { read -r l; [ -z "$l" ] && note "checkout: fsck clean after all of the above" || bad "checkout: final fsck" "$l"; }
fi
