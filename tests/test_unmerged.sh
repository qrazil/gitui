# `GIT_status.m31` -- unmerged index entries (stages 1/2/3) as their own
# category. The fixture index is written entry by entry with
# `git update-index --index-info` (every stage combination, plus ordinary
# staged / unstaged / untracked paths beside them); `t_unmerged` must agree
# with `git status --porcelain` and `git ls-files -u`, and a conflicted path
# must be in no other list. Shares `test.sh`'s shell, `$WORK`, `$LANGC`,
# `build`, `note`/`bad` and the counters.

umx="$WORK/unmerged_fx"
rm -rf "$umx"
mkdir -p "$umx"
(
    set -e
    cd "$umx"
    export GIT_AUTHOR_NAME=U GIT_AUTHOR_EMAIL=u@example.com GIT_COMMITTER_NAME=U GIT_COMMITTER_EMAIL=u@example.com
    export GIT_AUTHOR_DATE='1700000000 +0000' GIT_COMMITTER_DATE='1700000000 +0000'
    git init -q -b main .
    for f in a c f g h k m; do echo "base $f" >"$f"; done
    chmod +x m
    git add -A
    git commit -q -m base
    base=$(git rev-parse HEAD)
    ob() { echo "$1" | git hash-object -w --stdin; }
    # take every conflicted path out of the index, then write its stages
    git rm -q --cached a c f g
    {
        printf '100644 %s 1\ta\n100644 %s 2\ta\n100644 %s 3\ta\n' "$(ob a1)" "$(ob a2)" "$(ob a3)"
        printf '100644 %s 2\tb\n100755 %s 3\tb\n' "$(ob b2)" "$(ob b3)"
        printf '100644 %s 1\tc\n' "$(ob c1)"
        printf '100644 %s 2\td\n' "$(ob d2)"
        printf '100644 %s 3\te\n' "$(ob e3)"
        printf '100644 %s 1\tf\n100644 %s 3\tf\n' "$(ob f1)" "$(ob f3)"
        printf '100644 %s 1\tg\n100644 %s 2\tg\n' "$(ob g1)" "$(ob g2)"
    } | git update-index --index-info
    for f in a b d e f g; do echo "worktree $f" >"$f"; done   # c stays deleted
    echo "changed" >h                                         # unstaged modify
    echo "new" >i && git add i                                # staged add
    echo "tracked change" >k && git add k && echo "again" >k  # staged and unstaged
    echo "untracked" >j                                       # untracked
) >"$WORK/unmerged_fx.log" 2>&1 || bad "unmerged fixture" "$(tail -5 "$WORK/unmerged_fx.log")"

if build t_unmerged; then
    "$WORK/t_unmerged" "$umx/.git" "$umx" porcelain >"$umx.got" 2>"$umx.err"
    git -C "$umx" status --porcelain >"$umx.want"
    if diff "$umx.want" "$umx.got" >"$umx.diff"; then
        note "unmerged: porcelain output identical to git's ($(wc -l <"$umx.want") lines, all seven conflict codes)"
    else
        bad "unmerged: porcelain" "$(head -8 "$umx.diff")"
    fi
    for code in UU AA DD AU UA DU UD; do
        if grep -q "^$code " "$umx.got"; then :; else bad "unmerged: code $code missing"; fi
    done

    "$WORK/t_unmerged" "$umx/.git" "$umx" stages >"$umx.stages" 2>>"$umx.err"
    git -C "$umx" ls-files -u | awk -F'\t' '
        { split($1, f, " "); p = $2; id[p, f[3]] = f[2]; md[p, f[3]] = f[1]; seen[p] = 1; if (!(p in ord)) { ord[p] = ++n; name[n] = p } }
        END { for (i = 1; i <= n; i++) { p = name[i]; line = p
                for (s = 1; s <= 3; s++) line = line " " ((p, s) in id ? id[p, s] : "-")
                print line, md[p, 1] + 0, md[p, 2] + 0, md[p, 3] + 0 } }' >"$umx.stages.raw"
    # git prints modes in octal; ours are decimal
    : >"$umx.stages.want"
    while read -r p i1 i2 i3 m1 m2 m3; do
        echo "$p $i1 $i2 $i3 $((8#$m1)) $((8#$m2)) $((8#$m3))" >>"$umx.stages.want"
    done <"$umx.stages.raw"
    if diff "$umx.stages.want" "$umx.stages" >"$umx.diff"; then
        note "unmerged: ids and modes of all three stages equal git ls-files -u"
    else
        bad "unmerged: stages" "$(head -8 "$umx.diff")"
    fi
    if grep -q BUG "$umx.got"; then bad "unmerged: a conflicted path also in staged/unstaged"; else note "unmerged: conflicted paths are in no other list"; fi
    git -C "$umx" fsck --strict >"$umx.fsck" 2>&1 && note "unmerged: git fsck --strict clean" || bad "unmerged: fsck" "$(head -3 "$umx.fsck")"

    # no conflicts -> empty category, and an index without stages is unchanged
    git -C "$umx" rm -q --cached -f a b c d e f g
    "$WORK/t_unmerged" "$umx/.git" "$umx" stages >"$umx.stages2" 2>&1
    [ ! -s "$umx.stages2" ] && note "unmerged: none once the index has no stages" || bad "unmerged: stale" "$(cat "$umx.stages2")"
    "$WORK/t_unmerged" "$umx/.git" "$umx" porcelain >"$umx.got2" 2>&1
    git -C "$umx" status --porcelain >"$umx.want2"
    diff -q "$umx.want2" "$umx.got2" >/dev/null && note "unmerged: porcelain still identical after resolving" || bad "unmerged: resolved porcelain" "$(diff "$umx.want2" "$umx.got2" | head -5)"
fi
