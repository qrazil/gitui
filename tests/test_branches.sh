# `GIT_branches.m31` against real git: upstream tracking and ahead/behind
# (`git for-each-ref %(upstream:track)`, `git rev-list --left-right --count`),
# `git branch -u` / `git push -u` config, the tracking ref a push moves, and
# tags -- lightweight and annotated, byte for byte (the tag object's id is
# compared with the one `git tag -a` makes in a twin repository), listing and
# deleting, loose and packed. Shares `test.sh`'s shell, `$WORK`, `$LANGC`,
# `build`, `note`/`bad` and the counters. Git runs only in the disposable
# repositories made here, with a fixed identity and dates.

brx="$WORK/br_fx"
mkdir -p "$brx"

br_git() {
    env GIT_AUTHOR_NAME=Branch_Tester GIT_AUTHOR_EMAIL=b@example.com GIT_COMMITTER_NAME=Branch_Tester GIT_COMMITTER_EMAIL=b@example.com \
        GIT_AUTHOR_DATE="1700000000 +0100" GIT_COMMITTER_DATE="1700000000 +0100" git -C "$br_dir" "$@"
}

# br_commit <file> <text> <message> [date-offset-seconds]
br_commit() {
    printf '%s\n' "$2" > "$br_dir/$1"
    br_git add -A >/dev/null
    local when=$((1700000000 + ${4:-0}))
    GIT_AUTHOR_DATE="$when +0100" GIT_COMMITTER_DATE="$when +0100" br_git commit -q -m "$3"
}

# br_t <command> ...   run our tool on $br_dir
br_t() {
    br_out=$(env GIT_COMMITTER_NAME=Branch_Tester GIT_COMMITTER_EMAIL=b@example.com GIT_COMMITTER_DATE="1700000000 +0100" \
        "$WORK/t_branches" "$br_dir/.git" "$@" 2>&1)
    br_rc=$?
}

# A repo with a history: two commits on main.
br_twin() {
    br_dir="$brx/$1"
    rm -rf "$br_dir"
    git init -q -b main "$br_dir"
    br_commit a.txt one "c1" 0
    br_commit a.txt two "c2" 10
}

if build t_branches; then
    # ---- ahead/behind ------------------------------------------------------
    rm -rf "$brx/origin.git" "$brx/clone"
    git init -q --bare -b main "$brx/origin.git"
    br_dir="$brx/seed"; rm -rf "$br_dir"; git init -q -b main "$br_dir"
    br_commit a.txt one "c1" 0
    br_commit a.txt two "c2" 10
    br_git remote add origin "$brx/origin.git"
    br_git push -q -u origin main 2>/dev/null
    br_git checkout -q -b feat
    br_commit f.txt f1 "f1" 20
    br_git push -q -u origin feat 2>/dev/null
    git clone -q "$brx/origin.git" "$brx/clone" 2>/dev/null
    br_dir="$brx/clone"
    br_git checkout -q -b feat origin/feat 2>/dev/null
    br_git checkout -q main
    br_git checkout -q -b local          # no upstream
    br_git checkout -q main
    # origin gets 1 new commit on main, the clone gets 2
    br_dir="$brx/seed"; br_git checkout -q main; br_commit o.txt o1 "o1" 30; br_git push -q origin main 2>/dev/null
    br_dir="$brx/clone"
    br_git fetch -q origin
    br_commit m1.txt m1 "m1" 40
    br_commit m2.txt m2 "m2" 50
    br_git checkout -q feat; br_commit g.txt g1 "g1" 60; br_git checkout -q main
    br_git branch -q dotted --track main 2>/dev/null     # upstream "." (a local branch)
    br_git checkout -q local; br_commit l.txt l1 "l1" 70; br_git checkout -q main
    br_git update-ref refs/remotes/origin/zap "$(br_git rev-parse main)"
    br_git branch -q gone main; br_git branch -q -u origin/zap gone
    br_git update-ref -d refs/remotes/origin/zap
    gone_check=$(br_git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads/gone)
    names="main feat local dotted gone"
    br_t tracking $names
    # oracle: rev-list --left-right --count per branch with a live upstream
    ok=1; msg=""
    for b in main feat dotted; do
        up=$(br_git rev-parse --abbrev-ref "$b@{upstream}" 2>/dev/null)
        want=$(br_git rev-list --left-right --count "$b...$up" | tr '\t' ' ')
        got=$(echo "$br_out" | awk -v b="$b" '$1==b {print $2" "$3}')
        [ "$got" = "$want" ] || { ok=0; msg="$msg $b: got '$got' want '$want';"; }
        gotup=$(echo "$br_out" | awk -v b="$b" '$1==b {print $4}')
        [ "$gotup" = "$up" ] || { ok=0; msg="$msg $b upstream '$gotup' want '$up';"; }
    done
    [ "$ok" = 1 ]
    if [ $? = 0 ]; then note "branches: ahead/behind and upstream name match rev-list --left-right --count"; else bad "branches: ahead/behind" "$msg" "$br_out"; fi
    echo "$br_out" | grep -q "^local none$"
    if [ $? = 0 ]; then note "branches: a branch with no upstream has none"; else bad "branches: no upstream" "$br_out"; fi
    echo "$br_out" | grep -q "^gone gone "
    if [ $? = 0 ] && [ "$gone_check" = "gone [gone]" ]; then note "branches: a missing tracking ref is gone, as git says"; else bad "branches: gone" "$br_out" "$gone_check"; fi
    ok=1
    for b in main feat dotted gone local; do
        want=$(br_git for-each-ref --format='%(upstream:track)' "refs/heads/$b")
        br_t label "$b"
        [ "$b" = local ] && want=none
        [ "$br_out" = "$want" ] || { ok=0; msg="$b: got '$br_out' want '$want'"; }
    done
    if [ "$ok" = 1 ]; then note "branches: labels equal git's %(upstream:track)"; else bad "branches: label" "$msg"; fi
    br_t label main
    [ "$br_out" = "[ahead 2, behind 1]" ]
    if [ $? = 0 ]; then note "branches: '[ahead 2, behind 1]'"; else bad "branches: label text" "$br_out"; fi

    # ---- set upstream: config bytes equal git's -------------------------------
    br_twin up_git; git_dir=$br_dir
    br_git remote add origin "$brx/origin.git"; br_git branch -q feat
    br_git fetch -q origin 2>/dev/null
    br_git branch -q -u origin/feat feat
    br_twin up_ours; ours_dir=$br_dir
    br_git remote add origin "$brx/origin.git"; br_git branch -q feat
    br_git fetch -q origin 2>/dev/null
    br_t upstream feat origin refs/heads/feat
    [ "$br_out" = ok ] && cmp -s "$git_dir/.git/config" "$ours_dir/.git/config" \
        && [ "$(br_git rev-parse --abbrev-ref 'feat@{upstream}')" = origin/feat ]
    if [ $? = 0 ]; then note "branches: set_upstream writes the config git branch -u does, byte for byte"; else bad "branches: set_upstream" "$(diff "$git_dir/.git/config" "$ours_dir/.git/config")"; fi
    br_t upstream feat origin refs/heads/other
    [ "$(br_git config branch.feat.merge)" = refs/heads/other ] && [ "$(grep -c '^\[branch "feat"\]' "$br_dir/.git/config")" = 1 ]
    if [ $? = 0 ]; then note "branches: set_upstream again replaces, never duplicates"; else bad "branches: set_upstream twice" "$(cat "$br_dir/.git/config")"; fi

    # ---- record_push: the tracking ref and its reflog line ------------------------
    rm -rf "$brx/push_remote.git"; git init -q --bare -b main "$brx/push_remote.git"
    br_twin push_git; git_dir=$br_dir
    br_git remote add origin "$brx/push_remote.git"; br_git push -q -u origin main 2>/dev/null
    br_twin push_ours; ours_dir=$br_dir
    br_git remote add origin "$brx/push_remote.git"
    br_t push main origin "$(br_git rev-parse HEAD)"
    [ "$br_out" = ok ] \
        && [ "$(git -C "$git_dir" rev-parse refs/remotes/origin/main)" = "$(br_git rev-parse refs/remotes/origin/main)" ] \
        && [ "$(git -C "$git_dir" reflog -1 --format=%gs refs/remotes/origin/main)" = "$(br_git reflog -1 --format=%gs refs/remotes/origin/main)" ] \
        && [ -z "$(br_git fsck --strict --no-dangling 2>&1)" ]
    if [ $? = 0 ]; then note "branches: record_push moves the tracking ref with git's 'update by push' reflog line"; else bad "branches: record_push" "$br_out" "$(br_git reflog show origin/main)"; fi

    # ---- tags ---------------------------------------------------------------
    br_twin tag_git; git_dir=$br_dir
    br_twin tag_ours; ours_dir=$br_dir
    c2=$(br_git rev-parse HEAD)
    git_t() { br_dir=$git_dir; br_git "$@"; }
    ours_t() { br_dir=$ours_dir; br_t "$@"; }
    git_t tag v1
    ours_t tag v1 "$c2"
    [ "$br_out" = ok ] && [ "$(cat "$git_dir/.git/refs/tags/v1")" = "$(cat "$ours_dir/.git/refs/tags/v1")" ]
    if [ $? = 0 ]; then note "tags: lightweight tag equals git tag"; else bad "tags: lightweight" "$br_out"; fi
    ok=1; msg=""
    i=0
    for m in $'release one' $'two\nlines' $'first\n\n   spaced   trailing   \nleading' $'\n\n  lead blanks\n\n' $'inner\n\n\n\n\ncollapsed' $'  indented line' $'unicode caf\xc3\xa9 ok' $'tab\there  \n'; do
        i=$((i + 1))
        git_t tag -a -m "$m" "a$i"
        ours_t atag "a$i" "$c2" "$m"
        gid=$(cat "$git_dir/.git/refs/tags/a$i")
        if [ "$br_out" != "$gid" ]; then ok=0; msg="$msg a$i: ours '$br_out' git '$gid';"; fi
    done
    if [ "$ok" = 1 ]; then note "tags: annotated tags are byte-identical to git tag -a (same object id) for 8 messages"; else bad "tags: annotated" "$msg"; fi
    if [ -z "$(git -C "$ours_dir" fsck --strict --no-dangling 2>&1)" ] && [ "$(git -C "$ours_dir" cat-file -t a1)" = tag ] && [ "$(git -C "$ours_dir" tag -l -n1 a1)" = "a1              release one" ]; then
        note "tags: git reads our tags (fsck --strict, cat-file, tag -l -n1)"
    else bad "tags: git reading ours" "$(git -C "$ours_dir" fsck --strict --no-dangling 2>&1)"; fi
    # listing against for-each-ref
    ours_t tags
    want=$(git -C "$ours_dir" for-each-ref --format='%(refname:short) %(objectname) %(if)%(*objectname)%(then)%(*objectname)%(else)%(objectname)%(end) %(if)%(*objectname)%(then)a%(else)l%(end)' refs/tags | sort)
    got=$(echo "$br_out" | awk '{print $1" "$2" "$3" "$4}' | sort)
    if [ "$got" = "$want" ]; then note "tags: listing equals git for-each-ref (names, ids, peeled commit, kind)"; else bad "tags: listing" "got: $got" "want: $want"; fi
    ours_t tags
    echo "$br_out" | grep -q "^a1 .* a release one$" && echo "$br_out" | grep -q "^v1 .* l $"
    if [ $? = 0 ]; then note "tags: annotated subject is shown"; else bad "tags: subject" "$br_out"; fi
    # refusals
    ours_t tag v1 "$c2"; r1=$br_rc
    ours_t tag "bad name" "$c2"; r2=$br_rc
    ours_t atag x "$c2" "   "; r3=$br_rc
    ours_t tag "a..b" "$c2"; r4=$br_rc
    ours_t deltag nope; r5=$br_rc
    if [ $r1 != 0 ] && [ $r2 != 0 ] && [ $r3 != 0 ] && [ $r4 != 0 ] && [ $r5 != 0 ]; then note "tags: existing, invalid, empty-message and missing tags are refused"; else bad "tags: refusals" "$r1 $r2 $r3 $r4 $r5"; fi
    # delete: loose, then packed
    ours_t deltag v1
    [ "$br_out" = ok ] && ! git -C "$ours_dir" rev-parse -q --verify refs/tags/v1 >/dev/null
    if [ $? = 0 ]; then note "tags: delete a loose tag"; else bad "tags: delete loose" "$br_out"; fi
    git -C "$ours_dir" pack-refs --all
    ours_t deltag a2
    [ "$br_out" = ok ] && ! git -C "$ours_dir" rev-parse -q --verify refs/tags/a2 >/dev/null \
        && git -C "$ours_dir" rev-parse -q --verify refs/tags/a3 >/dev/null \
        && [ -z "$(git -C "$ours_dir" fsck --strict --no-dangling 2>&1)" ] \
        && [ "$(git -C "$ours_dir" tag -l | wc -l)" = 7 ]
    if [ $? = 0 ]; then note "tags: delete a packed tag (and its peeled line), others stay, git still reads packed-refs"; else bad "tags: delete packed" "$br_out" "$(cat "$ours_dir/.git/packed-refs")"; fi
fi
