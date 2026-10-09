# `GIT_pull.m31` and `GIT_pack.read_pack`, against real git as the oracle: packs real
# git writes (delta-compressed, ofs-delta, ref-delta and thin) are unpacked
# and judged by `git fsck --full`, and a pull from the real `git http-backend`
# servers `test_push.sh` left running is judged by `git status`, `git fsck`,
# `git ls-files -s` and a tree diff against the repository the server's
# content came from.
#
# Sourced from `test.sh` after `test_push.sh`: it reuses that script's two
# servers (`$pp_url`'s open one and `$pp_aurl`'s Basic-auth one, and their
# `$pp_root`) and its EXIT trap -- it starts nothing of its own.

pl_root="$WORK/pull"
mkdir -p "$pl_root"

# --- read_pack: every pack flavour git writes ---------------------------------

pl_src="$pl_root/src"
(
    set -e
    mkdir -p "$pl_src"
    cd "$pl_src"
    git init -q -b main .
    git config user.email pull@example.com
    git config user.name "Pull Tester"
    i=1
    while [ "$i" -le 12 ]; do
        seq 1 200 | sed "s/\$/ common line/" >big.txt
        echo "revision $i" >>big.txt
        mkdir -p d/e
        echo "file $i" >"d/e/f$i.txt"
        git add -A
        GIT_AUTHOR_DATE="172000000$i +0000" GIT_COMMITTER_DATE="172000000$i +0000" git commit -q -m "rev $i"
        i=$((i + 1))
    done
) >"$WORK/pull-src.log" 2>&1 && note "pull: source fixture built (12 commits of a mostly-unchanged 200-line file, so packs delta)" ||
    bad "pull source fixture" "$(tail -8 "$WORK/pull-src.log")"

if build t_pull; then
    pl_flavours_ok=1
    for pl_flavour in "ofs:--delta-base-offset" "ref:"; do
        pl_name=${pl_flavour%%:*}
        pl_flag=${pl_flavour#*:}
        pl_dst="$pl_root/unpack-$pl_name.git"
        git init -q --bare "$pl_dst"
        # shellcheck disable=SC2086
        echo main | git -C "$pl_src" pack-objects --revs --stdout $pl_flag >"$pl_root/$pl_name.pack" 2>/dev/null
        got=$("$WORK/t_pull" unpack "$pl_dst" "$pl_root/$pl_name.pack" 2>&1)
        want=$(git -C "$pl_src" rev-list --objects main | wc -l | tr -d " ")
        git -C "$pl_dst" update-ref refs/heads/main "$(git -C "$pl_src" rev-parse main)"
        if [ "$got" = "$want" ] && git -C "$pl_dst" fsck --full >"$WORK/pull-fsck-$pl_name.log" 2>&1 &&
            [ "$(git -C "$pl_dst" rev-list --objects main | sort | md5sum)" = "$(git -C "$pl_src" rev-list --objects main | sort | md5sum)" ]; then
            note "pack.read_pack: a $pl_name-delta pack from 'git pack-objects' unpacks to $got loose objects; git fsck --full clean, same object set"
        else
            pl_flavours_ok=0
            bad "pack.read_pack ($pl_name)" "unpacked '$got', expected $want" "$(cat "$WORK/pull-fsck-$pl_name.log" 2>/dev/null | head -5)"
        fi
    done
    # A thin pack: the receiving repository already has the base objects.
    pl_thin="$pl_root/thin.git"
    git init -q --bare "$pl_thin"
    git -C "$pl_src" push -q "$pl_thin" main~3:refs/heads/main >/dev/null 2>&1
    printf 'main\n^main~3\n' | git -C "$pl_src" pack-objects --revs --stdout --thin --delta-base-offset >"$pl_root/thin.pack" 2>/dev/null
    got=$("$WORK/t_pull" unpack "$pl_thin" "$pl_root/thin.pack" 2>&1)
    git -C "$pl_thin" update-ref refs/heads/main "$(git -C "$pl_src" rev-parse main)"
    if git -C "$pl_thin" fsck --full >"$WORK/pull-fsck-thin.log" 2>&1 &&
        [ "$(git -C "$pl_thin" rev-parse main)" = "$(git -C "$pl_src" rev-parse main)" ]; then
        note "pack.read_pack: a thin pack resolves its bases from the receiving repository ($got objects); git fsck --full clean"
    else
        bad "pack.read_pack (thin)" "unpacked '$got'" "$(head -5 "$WORK/pull-fsck-thin.log")"
    fi
    # Our own packs, via the push writer, round-trip too.
    pl_own="$pl_root/own.git"
    git init -q --bare "$pl_own"
    if build t_packwrite && "$WORK/t_packwrite" build "$pl_src/.git" "$pl_root/own.pack" >/dev/null 2>&1 &&
        "$WORK/t_pull" unpack "$pl_own" "$pl_root/own.pack" >/dev/null 2>&1 &&
        git -C "$pl_own" update-ref refs/heads/main "$(git -C "$pl_src" rev-parse main)" &&
        git -C "$pl_own" fsck --full >/dev/null 2>&1; then
        note "pack.read_pack: a pack written by GIT_pack_write.m31 reads back and fsck is clean"
    else
        bad "pack.read_pack (packwrite round trip)"
    fi
    # Garbage is refused.
    printf 'not a pack at all, not at all, not at all.....' >"$pl_root/junk.pack"
    if ! "$WORK/t_pull" unpack "$pl_root/own.git" "$pl_root/junk.pack" >/dev/null 2>&1; then
        note "pack.read_pack: bytes that are not a pack are refused"
    else
        bad "pack.read_pack accepted junk"
    fi
fi

# --- pull, against the real http-backend servers test_push.sh started ---------

if [ "${pp_up:-0}" = 1 ] && [ -x "$WORK/t_pull" ]; then
    pl_srvroot="$pp_root/srv"
    git init -q --bare -b main "$pl_srvroot/pull.git"
    git -C "$pl_srvroot/pull.git" config http.receivepack true
    pl_url="http://127.0.0.1:$pp_port/cgi-bin/git-http-backend-srv/pull.git"
    pl_srv="$pl_srvroot/pull.git"

    # `pl_work` is the "other developer's" repository: it pushes to the
    # server with real git, and is the oracle for what the server holds.
    pl_work="$pl_root/work"
    git clone -q "$pl_src" "$pl_work" >/dev/null 2>&1
    git -C "$pl_work" config user.email other@example.com
    git -C "$pl_work" config user.name Other
    git -C "$pl_work" push -q "$pl_url" main >/dev/null 2>&1
    git clone -q "$pl_url" "$pl_root/client" >/dev/null 2>&1
    pl_cl="$pl_root/client"
    pl_gd="$pl_cl/.git"
    git -C "$pl_cl" config user.email me@example.com
    git -C "$pl_cl" config user.name Me

    advance() {
        # advance <n>: the other developer commits n more, pushes, and the
        # server repacks so the next fetch is delta-compressed.
        local k=0
        while [ "$k" -lt "$1" ]; do
            pl_rev=$(($(git -C "$pl_work" rev-list --count main) + 1))
            echo "revision $pl_rev" >>"$pl_work/big.txt"
            echo "new $pl_rev" >"$pl_work/d/e/g$pl_rev.txt"
            git -C "$pl_work" add -A
            git -C "$pl_work" commit -q -m "upstream $pl_rev"
            k=$((k + 1))
        done
        git -C "$pl_work" push -q "$pl_url" main >/dev/null 2>&1
        git -C "$pl_srv" gc -q >/dev/null 2>&1
    }

    # --- already up to date ---------------------------------------------------
    got=$("$WORK/t_pull" pull "$pl_gd" "$pl_cl" "$pl_url" 2>&1)
    case "$got" in
        "up to date "*) note "pull: nothing new on the server reports 'up to date', repository unchanged" ;;
        *) bad "pull when up to date" "$got" ;;
    esac

    # --- fast-forward ----------------------------------------------------------
    echo "untracked, not in the way" >"$pl_cl/scratch.txt"
    advance 3
    chmod +x "$pl_work/d/e/f1.txt"
    git -C "$pl_work" add -A
    git -C "$pl_work" commit -q -m "make f1 executable"
    git -C "$pl_work" rm -q d/e/f2.txt
    git -C "$pl_work" commit -q -m "delete f2"
    git -C "$pl_work" push -q "$pl_url" main >/dev/null 2>&1
    git -C "$pl_srv" gc -q >/dev/null 2>&1
    pl_want_tip=$(git -C "$pl_work" rev-parse main)
    pl_old=$(git -C "$pl_cl" rev-parse HEAD)
    got=$("$WORK/t_pull" pull "$pl_gd" "$pl_cl" "$pl_url" 2>&1)
    if [ "$(git -C "$pl_cl" rev-parse HEAD)" = "$pl_want_tip" ] &&
        [ "$(git -C "$pl_cl" rev-parse refs/heads/main)" = "$pl_want_tip" ] &&
        [ "$(git -C "$pl_cl" rev-parse refs/remotes/origin/main)" = "$pl_want_tip" ] &&
        [ -z "$(git -C "$pl_cl" status --porcelain --untracked-files=no)" ] &&
        git -C "$pl_cl" fsck --full >"$WORK/pull-ff.fsck" 2>&1; then
        note "pull: fast-forwarded $(echo "$got" | awk '/^pulled / {print $4}') new objects; HEAD, branch and origin/main equal the server's tip; status clean; fsck clean"
    else
        bad "pull fast-forward" "$got" "$(git -C "$pl_cl" status --short | head -5)" "$(head -5 "$WORK/pull-ff.fsck")"
    fi
    pl_rl_ok=1
    for pl_rl in HEAD refs/heads/main; do
        pl_rl_line=$(git -C "$pl_cl" reflog show --format='%H %gs' "$pl_rl" | head -1)
        [ "$pl_rl_line" = "$pl_want_tip pull: Fast-forward" ] || { pl_rl_ok=0; pl_rl_why="$pl_rl: $pl_rl_line"; }
        [ "$(tail -1 "$pl_cl/.git/logs/$pl_rl" | cut -d' ' -f1)" = "$pl_old" ] || { pl_rl_ok=0; pl_rl_why="$pl_rl old id"; }
    done
    if [ $pl_rl_ok = 1 ] && [ "$(git -C "$pl_cl" reflog show --format='%gs' refs/remotes/origin/main | head -1)" = "pull: fast-forward" ]; then
        note "pull: HEAD and the branch each log 'pull: Fast-forward' from the old tip to the new, origin/main logs 'pull: fast-forward'"
    else
        bad "pull: reflog lines" "$pl_rl_why" "$(git -C "$pl_cl" reflog show --format='%H %gs' refs/remotes/origin/main | head -2)"
    fi
    if [ "$(git -C "$pl_cl" ls-files -s)" = "$(git -C "$pl_work" ls-files -s)" ] &&
        diff -r -x .git -x scratch.txt "$pl_cl" "$pl_work" >"$WORK/pull-ff.diff" 2>&1 &&
        [ -x "$pl_cl/d/e/f1.txt" ] && [ ! -e "$pl_cl/d/e/f2.txt" ] && [ -f "$pl_cl/scratch.txt" ]; then
        note "pull: the index and working tree match the server's content exactly (added, modified, deleted, +x); an unrelated untracked file survived"
    else
        bad "pull working tree content" "$(head -8 "$WORK/pull-ff.diff")"
    fi

    # --- refuses a dirty tree, before touching anything ------------------------
    advance 1
    echo "local edit" >>"$pl_cl/big.txt"
    pl_head=$(git -C "$pl_cl" rev-parse HEAD)
    got=$("$WORK/t_pull" pull "$pl_gd" "$pl_cl" "$pl_url" 2>&1)
    if [ $? -ne 0 ] && case "$got" in *uncommitted*) true ;; *) false ;; esac &&
        [ "$(git -C "$pl_cl" rev-parse HEAD)" = "$pl_head" ] && tail -1 "$pl_cl/big.txt" | grep -q "local edit"; then
        note "pull: an unstaged edit is refused ('uncommitted changes'); HEAD and the file are untouched"
    else
        bad "pull with an unstaged change" "$got"
    fi
    git -C "$pl_cl" add big.txt
    got=$("$WORK/t_pull" pull "$pl_gd" "$pl_cl" "$pl_url" 2>&1)
    if [ $? -ne 0 ] && [ "$(git -C "$pl_cl" rev-parse HEAD)" = "$pl_head" ] && [ -n "$(git -C "$pl_cl" diff --cached --name-only)" ]; then
        note "pull: a staged change is refused too; the index is untouched"
    else
        bad "pull with a staged change" "$got"
    fi
    git -C "$pl_cl" reset -q --hard
    got=$("$WORK/t_pull" pull "$pl_gd" "$pl_cl" "$pl_url" 2>&1)
    if [ "$(git -C "$pl_cl" rev-parse HEAD)" = "$(git -C "$pl_work" rev-parse main)" ]; then
        note "pull: once the tree is clean the same pull fast-forwards"
    else
        bad "pull after cleaning" "$got"
    fi

    # --- local ahead: nothing to pull ------------------------------------------
    echo local >"$pl_cl/local.txt"
    git -C "$pl_cl" add local.txt
    git -C "$pl_cl" commit -q -m "local only"
    pl_head=$(git -C "$pl_cl" rev-parse HEAD)
    got=$("$WORK/t_pull" pull "$pl_gd" "$pl_cl" "$pl_url" 2>&1)
    case "$got" in
        "up to date "*) [ "$(git -C "$pl_cl" rev-parse HEAD)" = "$pl_head" ] && note "pull: a branch ahead of the server is left alone ('up to date')" ;;
        *) bad "pull when ahead" "$got" ;;
    esac

    # --- diverged: refused, nothing moved, objects fetched ----------------------
    advance 1
    pl_theirs=$(git -C "$pl_work" rev-parse main)
    got=$("$WORK/t_pull" pull "$pl_gd" "$pl_cl" "$pl_url" 2>&1)
    if [ $? -ne 0 ] && case "$got" in *"not a fast-forward; merge/rebase not supported yet"*) true ;; *) false ;; esac &&
        [ "$(git -C "$pl_cl" rev-parse HEAD)" = "$pl_head" ] &&
        [ -z "$(git -C "$pl_cl" status --porcelain --untracked-files=no)" ] &&
        git -C "$pl_cl" cat-file -e "$pl_theirs" &&
        git -C "$pl_cl" fsck --full >/dev/null 2>&1; then
        note "pull: a diverged branch is refused ('not a fast-forward; merge/rebase not supported yet'); HEAD and tree unchanged, fetched objects kept, fsck clean"
    else
        bad "pull non-fast-forward" "$got"
    fi

    # --- other refusals -----------------------------------------------------------
    git -C "$pl_cl" checkout -q -b topic
    got=$("$WORK/t_pull" pull "$pl_gd" "$pl_cl" "$pl_url" 2>&1)
    if [ $? -ne 0 ] && case "$got" in *"no branch"*) true ;; *) false ;; esac; then
        note "pull: a branch the server does not have is refused"
    else
        bad "pull of a branch missing on the server" "$got"
    fi
    git -C "$pl_cl" checkout -q --detach
    got=$("$WORK/t_pull" pull "$pl_gd" "$pl_cl" "$pl_url" 2>&1)
    if [ $? -ne 0 ] && case "$got" in *detached*) true ;; *) false ;; esac; then
        note "pull: a detached HEAD is refused"
    else
        bad "pull on a detached HEAD" "$got"
    fi
    git -C "$pl_cl" checkout -q main

    # --- authentication ---------------------------------------------------------
    pl_asrv="$pp_root/srva/pull.git"
    git init -q --bare -b main "$pl_asrv"
    git -C "$pl_asrv" config http.receivepack true
    pl_aurl="http://127.0.0.1:$pp_aport/cgi-bin/git-http-backend-srva/pull.git"
    pl_acred="http://pusher:fixture-pw@127.0.0.1:$pp_aport/cgi-bin/git-http-backend-srva/pull.git"
    git -C "$pl_work" push -q "$pl_acred" main >/dev/null 2>&1
    git clone -q "$pl_acred" "$pl_root/aclient" >/dev/null 2>&1
    pl_acl="$pl_root/aclient"
    advance 1
    git -C "$pl_work" push -q "$pl_acred" main >/dev/null 2>&1
    pl_ahead=$(git -C "$pl_acl" rev-parse HEAD)
    got=$("$WORK/t_pull" pull "$pl_acl/.git" "$pl_acl" "$pl_aurl" 2>&1)
    if [ $? -ne 0 ] && [ "$(git -C "$pl_acl" rev-parse HEAD)" = "$pl_ahead" ]; then
        note "pull: no credentials against an authenticating server fails; nothing moved"
    else
        bad "pull without credentials" "$got"
    fi
    got=$("$WORK/t_pull" pull "$pl_acl/.git" "$pl_acl" "$pl_acred" 2>&1)
    if [ "$(git -C "$pl_acl" rev-parse HEAD)" = "$(git -C "$pl_work" rev-parse main)" ]; then
        case "$got" in
            *fixture-pw*) bad "pull leaked the password" "$got" ;;
            *) note "pull: credentials from the URL authenticate both the advertisement and the fetch; the password is never printed" ;;
        esac
    else
        bad "pull with URL credentials" "$got"
    fi
else
    note "pull: servers from test_push.sh are not up; server-backed pull checks skipped"
fi
