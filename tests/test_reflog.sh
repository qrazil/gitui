# `GIT_reflog.m31` and its wiring into ref updates -- reading what real git
# wrote, writing what real `git reflog` reads, `delete --rewrite` against git's
# own, and the lines `commit`, `commit --amend`, `checkout` and branch creation
# leave, each compared with what git leaves for the same operation. Shares
# `test.sh`'s shell, `$WORK`, `$LANGC`, `build`, `note`/`bad` and the counters.

rlx="$WORK/reflog_fx"
mkdir -p "$rlx"
# run a command with git's fixed identity and date in its environment
rl_run() { env GIT_AUTHOR_NAME=Log_Tester GIT_AUTHOR_EMAIL=log@example.com GIT_COMMITTER_NAME=Log_Tester GIT_COMMITTER_EMAIL=log@example.com GIT_AUTHOR_DATE='1700000000 +0000' GIT_COMMITTER_DATE='1700000000 +0000' "$@"; }

rl_git() { (cd "$1" && shift && env GIT_AUTHOR_NAME=Log_Tester GIT_AUTHOR_EMAIL=log@example.com GIT_COMMITTER_NAME=Log_Tester GIT_COMMITTER_EMAIL=log@example.com GIT_AUTHOR_DATE='1700000000 +0000' GIT_COMMITTER_DATE='1700000000 +0000' git "$@"); }

# the messages of a log file, oldest first
rl_msgs() { cut -f2- "$1" 2>/dev/null; }

rl_build_fixture() {
    local dir=$1
    rm -rf "$dir"
    git init -q -b main "$dir"
    (
        set -e
        cd "$dir"
        export GIT_AUTHOR_NAME=Log_Tester GIT_AUTHOR_EMAIL=log@example.com GIT_COMMITTER_NAME=Log_Tester GIT_COMMITTER_EMAIL=log@example.com
        export GIT_AUTHOR_DATE='1700000000 +0000' GIT_COMMITTER_DATE='1700000000 +0000'
        echo one >a.txt; git add a.txt; git commit -q -m 'first'
        echo two >a.txt; git commit -q -am 'second: with a colon'
        git switch -q -c feature
        echo three >b.txt; git add b.txt; git commit -q -m 'third'
        git switch -q main
        echo four >a.txt; git commit -q -am 'fourth'
        git checkout -q --detach HEAD~1
        git switch -q feature
        git switch -q main
        git merge -q --no-edit feature >/dev/null 2>&1 || true
        git tag light
        git tag -a -m annotated ann
    )
}

if build t_reflog; then
    # --- reading what git wrote -------------------------------------------------
    rl_build_fixture "$rlx/r1" >"$WORK/reflog_fx.log" 2>&1 || bad "reflog: fixture" "$(tail -5 "$WORK/reflog_fx.log")"
    for ref in HEAD refs/heads/main refs/heads/feature; do
        want=$(cd "$rlx/r1" && git reflog show --format='%H %gs' "$ref" | tac)
        got=$("$WORK/t_reflog" "$rlx/r1/.git" show "$ref" | sed 's/^[0-9a-f]\{40\} \([0-9a-f]\{40\}\) .*> [0-9]* [-+][0-9]* | /\1 /')
        if [ "$want" = "$got" ]; then
            note "reflog: read $ref ($(printf '%s\n' "$want" | grep -c .) lines) matches git reflog show"
        else
            bad "reflog: read $ref" "$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -8)"
        fi
    done
    want=$(cd "$rlx/r1" && git reflog show --format='%gn <%ge> %gd' HEAD | head -1)
    got=$("$WORK/t_reflog" "$rlx/r1/.git" show HEAD | tail -1 | sed 's/^[0-9a-f]* [0-9a-f]* \(.*> \)[0-9]* [-+][0-9]* | .*/\1/')
    [ "${want%% HEAD@*}" = "${got% }" ] && note "reflog: read ident fields" || bad "reflog: read ident fields" "git: $want" "ours: $got"
    got=$("$WORK/t_reflog" "$rlx/r1/.git" show refs/heads/nonesuch)
    [ -z "$got" ] && note "reflog: a ref with no log reads as empty" || bad "reflog: no log" "$got"

    # --- writing: git reads what we append ---------------------------------------
    rl_head=$(cd "$rlx/r1" && git rev-parse HEAD)
    rl_prev=$(cd "$rlx/r1" && git rev-parse HEAD~1)
    rl_run "$WORK/t_reflog" "$rlx/r1/.git" append refs/heads/feature "$rl_prev" "$rl_head" 'custom: a   message
 with	whitespace ' >/dev/null
    want="custom: a message with whitespace"
    got=$(cd "$rlx/r1" && git reflog show --format='%gs' refs/heads/feature | head -1)
    [ "$want" = "$got" ] && note "reflog: appended line is read by git reflog, message whitespace collapsed" || bad "reflog: append read by git" "want: $want" "got: $got"
    last=$(tail -1 "$rlx/r1/.git/logs/refs/heads/feature")
    want="$rl_prev $rl_head Log_Tester <log@example.com> 1700000000 +0000	$want"
    [ "$last" = "$want" ] && note "reflog: appended line is byte-exact (ident, date from GIT_COMMITTER_DATE)" || bad "reflog: byte-exact" "want: $want" "got: $last"
    rl_run "$WORK/t_reflog" "$rlx/r1/.git" append refs/heads/created - "$rl_head" 'branch: Created from HEAD' >/dev/null
    first=$(head -c 41 "$rlx/r1/.git/logs/refs/heads/created")
    [ "$first" = "0000000000000000000000000000000000000000 " ] && note "reflog: no old id is forty zeros" || bad "reflog: zeros" "$first"
    if (cd "$rlx/r1" && git fsck --strict >/dev/null 2>&1 && git reflog exists refs/heads/created >/dev/null 2>&1 && git reflog show --all >/dev/null 2>&1); then
        note "reflog: fsck --strict and git reflog both accept the file"
    else
        bad "reflog: fsck/reflog after append"
    fi

    # --- policy ----------------------------------------------------------------------
    pol=""
    for spec in "HEAD:yes" "refs/heads/zzz:yes" "refs/remotes/origin/x:yes" "refs/notes/c:yes" "refs/tags/t:no" "refs/stash:no"; do
        r=${spec%%:*}; w=${spec##*:}
        g=$("$WORK/t_reflog" "$rlx/r1/.git" should "$r")
        [ "$g" = "$w" ] || pol="$pol $r=$g(want $w)"
    done
    [ -z "$pol" ] && note "reflog: should_log defaults match git (heads, remotes, notes, HEAD yes; tags no)" || bad "reflog: should_log defaults" "$pol"
    (cd "$rlx/r1" && git config core.logAllRefUpdates always)
    [ "$("$WORK/t_reflog" "$rlx/r1/.git" should refs/tags/t)" = yes ] && note "reflog: core.logAllRefUpdates=always logs tags" || bad "reflog: always"
    (cd "$rlx/r1" && git config core.logAllRefUpdates false)
    [ "$("$WORK/t_reflog" "$rlx/r1/.git" should refs/heads/zzz)" = no ] && [ "$("$WORK/t_reflog" "$rlx/r1/.git" should refs/heads/main)" = yes ] &&
        note "reflog: core.logAllRefUpdates=false logs nothing new, but a ref with a log keeps logging" || bad "reflog: false"
    (cd "$rlx/r1" && git config --unset core.logAllRefUpdates)

    # --- delete, byte for byte against git reflog delete -----------------------------
    for spec in "HEAD 0 rewrite" "HEAD 2 rewrite" "HEAD 0 plain" "HEAD 3 plain" "refs/heads/main 1 rewrite" "refs/heads/feature 0 rewrite"; do
        set -- $spec
        r=$1 n=$2 mode=$3
        rm -rf "$rlx/d_git" "$rlx/d_ours"
        rl_build_fixture "$rlx/d_git" >/dev/null 2>&1
        cp -a "$rlx/d_git" "$rlx/d_ours"
        rlast=$(wc -l <"$rlx/d_git/.git/logs/$r")
        if [ "$mode" = rewrite ]; then
            (cd "$rlx/d_git" && git reflog delete --rewrite "$r@{$n}" >/dev/null 2>&1)
            "$WORK/t_reflog" "$rlx/d_ours/.git" delete "$r" "$n" rewrite >/dev/null
        else
            (cd "$rlx/d_git" && git reflog delete "$r@{$n}" >/dev/null 2>&1)
            "$WORK/t_reflog" "$rlx/d_ours/.git" delete "$r" "$n" >/dev/null
        fi
        if cmp -s "$rlx/d_git/.git/logs/$r" "$rlx/d_ours/.git/logs/$r"; then
            note "reflog: delete $r@{$n} ($mode, $rlast lines) is byte-identical to git reflog delete"
        else
            bad "reflog: delete $r@{$n} $mode" "$(diff "$rlx/d_git/.git/logs/$r" "$rlx/d_ours/.git/logs/$r" | head -6)"
        fi
    done
    out=$("$WORK/t_reflog" "$rlx/d_ours/.git" delete HEAD 99 rewrite)
    case $out in refused*) note "reflog: delete past the end is refused";; *) bad "reflog: delete past the end" "$out";; esac
    "$WORK/t_reflog" "$rlx/d_ours/.git" drop refs/heads/feature >/dev/null
    [ ! -e "$rlx/d_ours/.git/logs/refs/heads/feature" ] && [ -d "$rlx/d_ours/.git/logs/refs/heads" ] && note "reflog: delete_log removes the file" || bad "reflog: delete_log"
    mkdir -p "$rlx/d_ours/.git/logs/refs/heads/topic"
    printf '%040d %s Log_Tester <log@example.com> 1700000000 +0000\tx\n' 0 "$rl_head" >"$rlx/d_ours/.git/logs/refs/heads/topic/deep"
    "$WORK/t_reflog" "$rlx/d_ours/.git" drop refs/heads/topic/deep >/dev/null
    [ ! -e "$rlx/d_ours/.git/logs/refs/heads/topic" ] && [ -d "$rlx/d_ours/.git/logs" ] && note "reflog: delete_log prunes the empty directories it leaves" || bad "reflog: prune dirs"
fi

# --- ref updates: checkout, new branch, detach ------------------------------------
# The same operations, in two copies of one repository, one by git and one by
# this program, with the same fixed identity and date: the logs must be equal.
if build t_checkout; then
    rl_mk() {
        local dir=$1
        rm -rf "$dir"
        git init -q -b main "$dir"
        (
            set -e
            cd "$dir"
            export GIT_AUTHOR_NAME=Log_Tester GIT_AUTHOR_EMAIL=log@example.com GIT_COMMITTER_NAME=Log_Tester GIT_COMMITTER_EMAIL=log@example.com
            export GIT_AUTHOR_DATE='1700000000 +0000' GIT_COMMITTER_DATE='1700000000 +0000'
            echo one >a.txt; git add a.txt; git commit -q -m 'first'
            git switch -q -c feature
            echo two >b.txt; git add b.txt; git commit -q -m 'second'
            git switch -q main
        )
    }
    rl_mk "$rlx/c_git"; rl_mk "$rlx/c_ours"
    rl_feature=$(git -C "$rlx/c_git" rev-parse feature)
    rl_first=$(git -C "$rlx/c_git" rev-parse main)
    rl_tc() { rl_run "$WORK/t_checkout" "$rlx/c_ours/.git" "$rlx/c_ours" "$@" >/dev/null 2>&1; }
    rl_g() { rl_git "$rlx/c_git" "$@" >/dev/null 2>&1; }
    rl_g switch feature;                    rl_tc checkout feature
    rl_g checkout --detach "$rl_first";     rl_tc detach "$rl_first"
    rl_g switch main;                       rl_tc checkout main
    rl_g switch -c made;                    rl_tc new made
    rl_g switch main;                       rl_tc checkout main
    rl_g checkout --detach "$rl_feature";   rl_tc detach "$rl_feature"
    rl_g switch -c from-detached;           rl_tc new from-detached
    for f in HEAD refs/heads/made refs/heads/from-detached; do
        if cmp -s "$rlx/c_git/.git/logs/$f" "$rlx/c_ours/.git/logs/$f"; then
            note "reflog: checkout/detach/new-branch log for $f is byte-identical to git's ($(wc -l <"$rlx/c_git/.git/logs/$f") lines)"
        else
            bad "reflog: checkout log for $f" "$(diff "$rlx/c_git/.git/logs/$f" "$rlx/c_ours/.git/logs/$f" | head -10)"
        fi
    done
    rl_g switch main
    # an unborn repository: switching to a new branch writes no log, as in git
    rm -rf "$rlx/u_git" "$rlx/u_ours"
    git init -q -b main "$rlx/u_git"; git init -q -b main "$rlx/u_ours"
    rl_git "$rlx/u_git" switch -q -c other >/dev/null 2>&1
    rl_run "$WORK/t_checkout" "$rlx/u_ours/.git" "$rlx/u_ours" new other >/dev/null 2>&1
    if [ "$(ls "$rlx/u_git/.git/logs" 2>/dev/null | wc -l)" = "$(ls "$rlx/u_ours/.git/logs" 2>/dev/null | wc -l)" ]; then
        note "reflog: new branch on an unborn repository writes no log, like git"
    else
        bad "reflog: unborn new branch" "git: $(ls -R "$rlx/u_git/.git/logs" 2>&1)" "ours: $(ls -R "$rlx/u_ours/.git/logs" 2>&1)"
    fi
    (cd "$rlx/c_ours" && git fsck --strict >/dev/null 2>&1) && note "reflog: fsck --strict clean after the checkouts" || bad "reflog: fsck after checkouts"
fi

# --- commit and commit --amend, through the client --------------------------------
if [ -x "$WORK/t_gitclient_ops" ] || build t_gitclient_ops; then
    cm="$rlx/commit"
    rm -rf "$cm"
    git init -q -b main "$cm"
    git -C "$cm" config user.name Log_Tester
    git -C "$cm" config user.email log@example.com
    ops() { rl_run "$WORK/t_gitclient_ops" "$cm/.git" "$cm" "$@" >"$WORK/reflog_ops.out" 2>&1; }
    echo one >"$cm/a.txt"; git -C "$cm" add a.txt
    printf 'first commit\n\nbody text\n' >"$cm/.git/COMMIT_EDITMSG"; ops commit
    echo two >>"$cm/a.txt"; git -C "$cm" add a.txt
    printf 'second commit\n' >"$cm/.git/COMMIT_EDITMSG"; ops commit
    ops amend
    echo three >>"$cm/a.txt"; git -C "$cm" add a.txt
    printf 'third commit\n' >"$cm/.git/COMMIT_EDITMSG"; ops commit
    want=$'commit (initial): first commit\ncommit: second commit\ncommit (amend): second commit\ncommit: third commit'
    for f in HEAD refs/heads/main; do
        got=$(rl_msgs "$cm/.git/logs/$f")
        [ "$got" = "$want" ] && note "reflog: commit / amend log messages on $f match git's wording" || bad "reflog: commit messages on $f" "want: $want" "got: $got"
    done
    chain=$(awk 'NR>1 && $1!=prev {print "broken at line " NR} {prev=$2}' "$cm/.git/logs/HEAD")
    tip=$(awk 'END{print $2}' "$cm/.git/logs/HEAD")
    [ -z "$chain" ] && [ "$tip" = "$(git -C "$cm" rev-parse HEAD)" ] && note "reflog: old ids chain to the previous new id and the last new id is the tip" || bad "reflog: chain" "$chain tip=$tip"
    got=$(git -C "$cm" reflog show --format='%gs' | tr '\n' '|')
    [ "$got" = "commit: third commit|commit (amend): second commit|commit: second commit|commit (initial): first commit|" ] && note "reflog: git reflog reads the client's log" || bad "reflog: git reads client log" "$got"
    (cd "$cm" && git fsck --strict 2>&1 | grep -v '^Checking\|dangling' | head -3 | grep . >/dev/null) && bad "reflog: fsck after commits" || note "reflog: fsck --strict clean after commits"
fi
