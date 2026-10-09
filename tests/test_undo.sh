# `GIT_undo.m31` (the Z key's engine) against real git. Real git makes the
# history (commit, amend, reset, checkout, merge, rebase); we undo and redo;
# real git then reads the result (`git status`, `git fsck --strict`, the
# reflog) and carries on from it. Shares `test.sh`'s shell, `$WORK`, `$LANGC`,
# `build`, `note`/`bad` and the counters. Git runs only in the disposable
# repositories made here, with a fixed identity and dates.

unx="$WORK/undo_fx"
mkdir -p "$unx"

un_git() {
    env GIT_AUTHOR_NAME=Undo_Tester GIT_AUTHOR_EMAIL=u@example.com GIT_COMMITTER_NAME=Undo_Tester GIT_COMMITTER_EMAIL=u@example.com \
        GIT_AUTHOR_DATE="1700000000 +0000" GIT_COMMITTER_DATE="1700000000 +0000" git -C "$un_dir" "$@"
}

# un_commit <file> <text> <message>
un_commit() {
    printf '%s\n' "$2" > "$un_dir/$1"
    un_git add -A >/dev/null
    un_git commit -q -m "$3"
}

un_fresh() {
    un_dir="$unx/$1"
    rm -rf "$un_dir"
    git init -q -b main "$un_dir"
    un_commit a.txt one "c1"
    un_commit a.txt two "c2"
    un_commit b.txt bee "c3"
}

# un_t <mode>   run our tool, output in $un_out, status in $un_rc
un_t() {
    un_out=$("$WORK/t_undo" "$un_dir/.git" "$un_dir" "$1" 2>&1)
    un_rc=$?
}

# un_clean <label>   fsck strict, status clean, index == HEAD
un_clean() {
    local f s
    f=$(un_git fsck --strict --no-dangling 2>&1)
    s=$(un_git status --porcelain 2>&1)
    [ -z "$f" ] && [ -z "$s" ] && return 0
    bad "undo: $1: not clean" "fsck: $f" "status: $s"
    return 1
}

# un_expect <label> <condition-result 0/1> [detail]
un_ok() { if [ "$2" = 0 ]; then note "undo: $1"; else bad "undo: $1" "${3:-}"; fi; }

if build t_undo; then
    # 1. plain commits: undo, undo, refused at the first commit, redo twice
    un_fresh basic
    c1=$(un_git rev-parse HEAD~2); c2=$(un_git rev-parse HEAD~1); c3=$(un_git rev-parse HEAD)
    un_t plan
    [ "$(echo "$un_out" | head -1)" = "undo: undo: commit: c3 | reset branch main to ${c2:0:7}" ] && [ "$(echo "$un_out" | tail -1)" = "redo: - nothing to redo" ]
    un_ok "plan names the step and the target" $? "$un_out"
    un_t undo
    [ "$un_out" = ok ] && [ "$(un_git rev-parse HEAD)" = "$c2" ] && [ ! -e "$un_dir/b.txt" ] && un_clean "after undo commit"
    un_ok "undo a commit: HEAD, branch, worktree, index" $? "$un_out"
    [ "$(un_git reflog -1 --format=%gs)" = "undo: commit: c3" ] && [ "$(un_git reflog -1 main --format=%gs)" = "undo: commit: c3" ] && [ "$(un_git rev-parse 'HEAD@{1}')" = "$c3" ]
    un_ok "the undo is a reflog line on HEAD and on the branch" $? "$(un_git reflog -3)"
    un_t undo
    [ "$un_out" = ok ] && [ "$(un_git rev-parse HEAD)" = "$c1" ] && [ "$(cat "$un_dir/a.txt")" = one ] && un_clean "after second undo"
    un_ok "undo again goes one step further back" $? "$un_out"
    un_t undo
    [ "$un_rc" != 0 ] && echo "$un_out" | grep -q "first step"
    un_ok "the first commit cannot be undone" $? "$un_out"
    un_t redo
    [ "$un_out" = ok ] && [ "$(un_git rev-parse HEAD)" = "$c2" ] && [ "$(cat "$un_dir/a.txt")" = two ] && un_clean "after redo"
    un_ok "redo" $? "$un_out"
    [ "$(un_git reflog -1 --format=%gs)" = "redo: commit: c2" ]
    un_ok "redo is a reflog line" $? "$(un_git reflog -2)"
    un_t redo
    [ "$un_out" = ok ] && [ "$(un_git rev-parse HEAD)" = "$c3" ] && [ "$(cat "$un_dir/b.txt")" = bee ] && un_clean "after second redo"
    un_ok "redo to the original state" $? "$un_out"
    un_t redo
    [ "$un_rc" != 0 ] && echo "$un_out" | grep -q "nothing to redo"
    un_ok "nothing left to redo" $? "$un_out"

    # 2. real git continues state we created, and a new commit ends redo
    un_t undo
    un_commit c.txt see "c4"
    c4=$(un_git rev-parse HEAD)
    [ "$(un_git rev-parse HEAD^)" = "$c2" ] && un_clean "git commit after our undo"
    un_ok "git commits on top of our undo" $? "$(un_git log --oneline | head -3)"
    un_t plan
    echo "$un_out" | grep -q "^redo: - nothing to redo" && echo "$un_out" | grep -q "^undo: undo: commit: c4"
    un_ok "a new commit clears redo" $? "$un_out"
    un_t undo; un_t undo
    [ "$(un_git rev-parse HEAD)" = "$c1" ] && un_git reset -q --hard "$c4" && un_clean "git reset after our undos"
    un_ok "git resets to a commit our undo left behind" $? "$(un_git reflog -5)"

    # 3. we continue state git created: reset --hard, amend
    un_fresh reset
    c2=$(un_git rev-parse HEAD~1); c3=$(un_git rev-parse HEAD)
    un_git reset -q --hard HEAD~1
    un_t plan
    echo "$un_out" | grep -q "^undo: undo: reset: moving to HEAD~1"
    un_ok "plan sees git reset --hard" $? "$un_out"
    un_t undo
    [ "$(un_git rev-parse HEAD)" = "$c3" ] && [ "$(cat "$un_dir/b.txt")" = bee ] && un_clean "undo reset"
    un_ok "undo a git reset --hard restores branch and files" $? "$un_out"

    un_fresh amend
    c3=$(un_git rev-parse HEAD)
    printf 'changed\n' > "$un_dir/b.txt"
    un_git add b.txt; un_git commit -q --amend -m "c3 amended"
    un_t undo
    [ "$(un_git rev-parse HEAD)" = "$c3" ] && [ "$(cat "$un_dir/b.txt")" = bee ] && un_clean "undo amend"
    un_ok "undo an amend" $? "$un_out"
    un_t redo
    [ "$(un_git log -1 --format=%s)" = "c3 amended" ] && [ "$(cat "$un_dir/b.txt")" = changed ] && un_clean "redo amend"
    un_ok "redo an amend" $? "$un_out"

    # 4. checkout: branch to branch, to a detached commit, and back
    un_fresh checkout
    un_git checkout -q -b feature
    un_commit f.txt eff "f1"
    un_git checkout -q main
    un_t plan
    echo "$un_out" | grep -q "^undo: undo: checkout feature -> main | back to feature"
    un_ok "plan names a checkout" $? "$un_out"
    un_t undo
    [ "$un_out" = ok ] && [ "$(un_git symbolic-ref HEAD)" = refs/heads/feature ] && [ -f "$un_dir/f.txt" ] && un_clean "undo checkout"
    un_ok "undo a checkout: on the branch again with its files" $? "$un_out"
    [ "$(un_git reflog -1 --format=%gs)" = "undo: checkout: moving from feature to main" ]
    un_ok "the checkout undo is a HEAD reflog line" $? "$(un_git reflog -2)"
    un_t redo
    [ "$un_out" = ok ] && [ "$(un_git symbolic-ref HEAD)" = refs/heads/main ] && [ ! -e "$un_dir/f.txt" ] && un_clean "redo checkout"
    un_ok "redo a checkout" $? "$un_out"
    un_git checkout -q --detach HEAD~1
    un_t undo
    [ "$un_out" = ok ] && [ "$(un_git symbolic-ref HEAD)" = refs/heads/main ] && un_clean "undo detach"
    un_ok "undo a detach goes back to the branch" $? "$un_out"
    un_git checkout -q feature
    un_git branch -q -D main 2>/dev/null
    un_t plan
    echo "$un_out" | grep -q "no such branch now"
    un_ok "undo to a deleted branch detaches and says so" $? "$un_out"
    un_t undo
    [ "$un_out" = ok ] && ! un_git symbolic-ref -q HEAD >/dev/null && un_clean "undo to deleted branch"
    un_ok "undo to a deleted branch leaves HEAD detached at the old commit" $? "$un_out"

    # 5. merge, then undo and redo
    un_fresh merge
    un_git checkout -q -b side
    un_commit s.txt ess "s1"
    un_git checkout -q main
    un_commit m.txt em "m1"
    pre=$(un_git rev-parse HEAD)
    un_git merge -q --no-ff -m "merge side" side >/dev/null
    post=$(un_git rev-parse HEAD)
    un_t undo
    [ "$un_out" = ok ] && [ "$(un_git rev-parse HEAD)" = "$pre" ] && [ ! -e "$un_dir/s.txt" ] && un_clean "undo merge"
    un_ok "undo a merge commit" $? "$un_out"
    un_t redo
    [ "$un_out" = ok ] && [ "$(un_git rev-parse HEAD)" = "$post" ] && [ -f "$un_dir/s.txt" ] && un_clean "redo merge"
    un_ok "redo a merge" $? "$un_out"

    # 6. a rebase is one step
    un_fresh rebase
    un_git checkout -q -b topic
    un_commit t1.txt t1 "t1"
    un_commit t2.txt t2 "t2"
    pre=$(un_git rev-parse HEAD)
    un_git checkout -q main
    un_commit m.txt em "m1"
    un_git checkout -q topic
    un_git rebase -q main >/dev/null 2>&1
    post=$(un_git rev-parse HEAD)
    [ "$pre" != "$post" ]
    un_ok "(fixture) rebase moved the branch" $?
    un_t undo
    [ "$un_out" = ok ] && [ "$(un_git rev-parse HEAD)" = "$pre" ] && [ "$(un_git rev-parse topic)" = "$pre" ] && [ ! -e "$un_dir/m.txt" ] && un_clean "undo rebase"
    un_ok "undo a whole rebase in one step" $? "$un_out $(un_git reflog -3)"
    un_t redo
    [ "$un_out" = ok ] && [ "$(un_git rev-parse HEAD)" = "$post" ] && un_clean "redo rebase"
    un_ok "redo a rebase" $? "$un_out"

    # 7. refusals: worktree in the way, unrelated changes kept, merge and rebase in progress
    un_fresh dirty
    printf 'mine\n' > "$un_dir/b.txt"
    h=$(un_git rev-parse HEAD)
    un_t undo
    [ "$un_rc" != 0 ] && [ "$(un_git rev-parse HEAD)" = "$h" ] && [ "$(cat "$un_dir/b.txt")" = mine ]
    un_ok "a local change to a file the undo touches refuses it, nothing written" $? "$un_out"
    printf 'keep\n' > "$un_dir/a.txt"
    un_git checkout -q -- b.txt
    un_t undo
    [ "$un_out" = ok ] && [ "$(cat "$un_dir/a.txt")" = keep ] && [ "$(un_git status --porcelain)" = " M a.txt" ]
    un_ok "an unrelated local change is kept through an undo" $? "$un_out $(un_git status --porcelain)"

    un_fresh midmerge
    un_git checkout -q -b other
    un_commit a.txt other "o1"
    un_git checkout -q main
    un_commit a.txt mine "m1"
    un_git merge other >/dev/null 2>&1
    h=$(un_git rev-parse HEAD)
    un_t undo
    [ "$un_rc" != 0 ] && echo "$un_out" | grep -q "merge is in progress" && [ "$(un_git rev-parse HEAD)" = "$h" ]
    un_ok "undo is refused mid-merge" $? "$un_out"
    un_t plan
    echo "$un_out" | grep -q "^busy: a merge is in progress"
    un_ok "the plan says why" $? "$un_out"
    un_git merge --abort

    un_fresh midrebase
    un_git checkout -q -b other
    un_commit a.txt other "o1"
    un_git checkout -q main
    un_commit a.txt mine "m1"
    un_git rebase other >/dev/null 2>&1
    h=$(un_git rev-parse HEAD)
    un_t undo
    [ "$un_rc" != 0 ] && echo "$un_out" | grep -q "rebase is in progress" && [ "$(un_git rev-parse HEAD)" = "$h" ]
    un_ok "undo is refused mid-rebase" $? "$un_out"
    un_git rebase --abort >/dev/null 2>&1
    un_t plan
    echo "$un_out" | grep -q "^undo: undo: commit: m1 |"
    un_ok "a rebase abort is not an undo step: undo targets the commit before it" $? "$un_out"

    # 8. unborn HEAD, and git continuing after our undo of a checkout
    rm -rf "$unx/unborn"; un_dir="$unx/unborn"; git init -q -b main "$un_dir"
    un_t plan
    echo "$un_out" | grep -q "^undo: - nothing to undo"
    un_ok "a repository with no history has nothing to undo" $? "$un_out"
    un_fresh after_checkout
    un_git checkout -q -b feature
    un_commit f.txt eff "f1"
    un_git checkout -q main
    un_t undo
    un_commit g.txt gee "f2"
    [ "$(un_git rev-parse --abbrev-ref HEAD)" = feature ] && [ "$(un_git rev-list --count feature)" = 5 ] && un_clean "git commit after checkout undo"
    un_ok "git commits on the branch our checkout undo returned to" $? "$(un_git log --oneline | head -3)"
fi
