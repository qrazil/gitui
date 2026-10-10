# `GIT_graph.m31` -- merge bases (criss-cross included), is_ancestor,
# ahead/behind and rev_list, driven through `t_graph` over generated histories
# with merges and checked against real git (`merge-base --all`,
# `merge-base --is-ancestor`, `rev-list --left-right --count`, `rev-list`).
# Shares `test.sh`'s shell, `$WORK`, `$LANGC`, `build`, `note`/`bad` and the
# counters.

grx="$WORK/graph_fx"
mkdir -p "$grx"

# gr_make <dir> <seed> <commits> <date step> <ties>  -- a random DAG of empty-tree
# commits: each has one recent parent, one in four a second, one in twenty none
# (a second root, so some pairs have no merge base). With <ties> = 1 several
# commits share a date.
gr_make() {
    local dir=$1 seed=$2 count=$3 step=$4 ties=$5
    rm -rf "$dir"
    git init -q -b main "$dir"
    (
        cd "$dir"
        export GIT_AUTHOR_NAME=Graph_Tester GIT_AUTHOR_EMAIL=g@example.com GIT_COMMITTER_NAME=Graph_Tester GIT_COMMITTER_EMAIL=g@example.com
        RANDOM=$seed
        tree=$(git hash-object -t tree -w /dev/null)
        ids=()
        i=0
        while [ $i -lt $count ]; do
            when=$((1700000000 + i * step))
            [ "$ties" = 1 ] && when=$((1700000000 + (i / 3) * step))
            export GIT_AUTHOR_DATE="$when +0000" GIT_COMMITTER_DATE="$when +0000"
            args=()
            if [ $i -gt 0 ] && [ $((RANDOM % 20)) -ne 0 ]; then
                lo=$((i > 7 ? i - 7 : 0))
                p1=$((lo + RANDOM % (i - lo)))
                args+=(-p "${ids[$p1]}")
                if [ $((RANDOM % 4)) -eq 0 ]; then
                    p2=$((RANDOM % i))
                    [ $p2 -ne $p1 ] && args+=(-p "${ids[$p2]}")
                fi
            fi
            ids+=("$(git commit-tree ${args[@]+"${args[@]}"} -m "c$i" "$tree")")
            i=$((i + 1))
        done
        printf "%s\n" ${ids[@]+"${ids[@]}"} >ids
        git update-ref refs/heads/main "${ids[$((count - 1))]}"
    )
}

# gr_check <label> <dir> <pairs> <revlists> -- compare every pair and rev-list
gr_check() {
    local label=$1 dir=$2 npairs=$3 nlists=$4
    local n
    n=$(wc -l <"$dir/ids")
    : >"$dir/pairs"; : >"$dir/lists"; : >"$dir/pairs.want"; : >"$dir/lists.want"
    RANDOM=$n
    local k a b c d
    for ((k = 0; k < npairs; k++)); do
        a=$(sed -n "$((RANDOM % n + 1))p" "$dir/ids")
        b=$(sed -n "$((RANDOM % n + 1))p" "$dir/ids")
        echo "$a $b" >>"$dir/pairs"
        local bases lr anc1 anc2
        bases=$(git -C "$dir" merge-base --all "$a" "$b" 2>/dev/null | sort | tr '\n' ' ')
        bases=${bases% }
        lr=$(git -C "$dir" rev-list --left-right --count "$a...$b")
        anc1=0; git -C "$dir" merge-base --is-ancestor "$a" "$b" && anc1=1
        anc2=0; git -C "$dir" merge-base --is-ancestor "$b" "$a" && anc2=1
        echo "$a $b | $bases | ${lr/	/ } | $anc1 $anc2" >>"$dir/pairs.want"
    done
    for ((k = 0; k < nlists; k++)); do
        a=$(sed -n "$((RANDOM % n + 1))p" "$dir/ids")
        b=$(sed -n "$((RANDOM % n + 1))p" "$dir/ids")
        c=$(sed -n "$((RANDOM % n + 1))p" "$dir/ids")
        d=$(sed -n "$((RANDOM % n + 1))p" "$dir/ids")
        local spec
        case $((k % 4)) in
            0) spec="$a ^$b" ;;
            1) spec="$a $b ^$c" ;;
            2) spec="$a $b ^$c ^$d" ;;
            3) spec="$a" ;;
        esac
        echo "$spec" >>"$dir/lists"
        local inc="" exc="" w
        for w in $spec; do
            case $w in ^*) exc="$exc $w" ;; *) inc="$inc $w" ;; esac
        done
        echo "$spec => $(git -C "$dir" rev-list $inc $exc | tr '\n' ' ' | sed 's/ $//')" >>"$dir/lists.want"
    done
    "$WORK/t_graph" "$dir/.git" pairs "$dir/pairs" >"$dir/pairs.got" 2>&1
    "$WORK/t_graph" "$dir/.git" revlist "$dir/lists" >"$dir/lists.got" 2>&1
    if cmp -s "$dir/pairs.got" "$dir/pairs.want"; then
        note "graph: $label: merge bases, ahead/behind and is_ancestor equal git on $npairs pairs ($(awk -F' [|] ' '$2 ~ / / {n++} END {print n+0}' "$dir/pairs.want") with several bases, $(awk -F' [|] ' '$2 == "" {n++} END {print n+0}' "$dir/pairs.want") with none)"
    else
        bad "graph: $label: pairs" "$(diff "$dir/pairs.want" "$dir/pairs.got" | head -8)"
    fi
    if cmp -s "$dir/lists.got" "$dir/lists.want"; then
        note "graph: $label: rev_list equals git rev-list, order included, on $nlists include/exclude sets"
    else
        bad "graph: $label: rev_list" "$(diff "$dir/lists.want" "$dir/lists.got" | head -8)"
    fi
}

if build t_graph; then
    gr_make "$grx/g1" 11 70 60 0
    gr_check "70 commits, distinct dates" "$grx/g1" 90 40
    gr_make "$grx/g2" 29 90 30 1
    gr_check "90 commits, runs of equal dates" "$grx/g2" 90 40
    (cd "$grx/g2" && git repack -q -a -d && git prune-packed) >/dev/null 2>&1
    gr_check "90 commits, packed" "$grx/g2" 40 20
    (cd "$grx/g2" && git fsck --strict >/dev/null 2>&1) && note "graph: fixture fsck --strict clean" || bad "graph: fixture fsck"

    # a criss-cross: O <- X, O <- Y; M1 = merge(X, Y); M2 = merge(Y, X); the
    # merge bases of M1 and M2 are X and Y, both
    cc="$grx/cc"
    rm -rf "$cc"; git init -q -b main "$cc"
    (
        cd "$cc"
        export GIT_AUTHOR_NAME=Graph_Tester GIT_AUTHOR_EMAIL=g@example.com GIT_COMMITTER_NAME=Graph_Tester GIT_COMMITTER_EMAIL=g@example.com
        tree=$(git hash-object -t tree -w /dev/null)
        mk() { local t=$1; shift; GIT_AUTHOR_DATE="$t +0000" GIT_COMMITTER_DATE="$t +0000" git commit-tree "$@" -m "m$t" "$tree"; }
        o=$(mk 1700000001)
        x=$(mk 1700000002 -p "$o")
        y=$(mk 1700000003 -p "$o")
        m1=$(mk 1700000004 -p "$x" -p "$y")
        m2=$(mk 1700000005 -p "$y" -p "$x")
        x2=$(mk 1700000006 -p "$m1")
        y2=$(mk 1700000007 -p "$m2")
        m3=$(mk 1700000008 -p "$x2" -p "$y2")
        m4=$(mk 1700000009 -p "$y2" -p "$x2")
        printf '%s\n' "$o" "$x" "$y" "$m1" "$m2" "$x2" "$y2" "$m3" "$m4" >ids
        git update-ref refs/heads/main "$m4"
    )
    cc_ids=($(cat "$cc/ids"))
    printf '%s %s\n' "${cc_ids[3]}" "${cc_ids[4]}" "${cc_ids[5]}" "${cc_ids[6]}" "${cc_ids[7]}" "${cc_ids[8]}" >"$cc/pairs"
    "$WORK/t_graph" "$cc/.git" pairs "$cc/pairs" >"$cc/pairs.got" 2>&1
    got=$(sed -n 1p "$cc/pairs.got" | awk -F' [|] ' '{print $2}')
    want=$(printf '%s\n' "${cc_ids[1]}" "${cc_ids[2]}" | sort | tr '\n' ' ' | sed 's/ $//')
    gitwant=$(git -C "$cc" merge-base --all "${cc_ids[3]}" "${cc_ids[4]}" | sort | tr '\n' ' ' | sed 's/ $//')
    if [ "$got" = "$want" ] && [ "$want" = "$gitwant" ]; then
        note "graph: criss-cross gives both merge bases (X and Y), as git does"
    else
        bad "graph: criss-cross" "ours: $got" "git: $gitwant" "want: $want"
    fi
    got=$(sed -n 3p "$cc/pairs.got" | awk -F' [|] ' '{print $2}')
    gitwant=$(git -C "$cc" merge-base --all "${cc_ids[7]}" "${cc_ids[8]}" | sort | tr '\n' ' ' | sed 's/ $//')
    [ "$got" = "$gitwant" ] && [ "$(echo "$got" | wc -w)" -ge 2 ] && note "graph: second-level criss-cross agrees with git ($(echo "$got" | wc -w) bases)" || bad "graph: second criss-cross" "ours: $got" "git: $gitwant"

    # a ref name never reaches here, but a non-commit id is a clean error
    blob=$(echo hi | git -C "$cc" hash-object -w --stdin)
    out=$("$WORK/t_graph" "$cc/.git" count "$blob" 2>&1)
    case $out in refused*) note "graph: a blob id is refused ($out)";; *) bad "graph: blob id" "$out";; esac
    out=$("$WORK/t_graph" "$cc/.git" count 0123456789012345678901234567890123456789 2>&1)
    case $out in refused*) note "graph: a missing id is refused ($out)";; *) bad "graph: missing id" "$out";; esac
    [ "$("$WORK/t_graph" "$cc/.git" count "${cc_ids[8]}")" = "$(git -C "$cc" rev-list "${cc_ids[8]}" | wc -l)" ] && note "graph: ancestors count equals git rev-list" || bad "graph: ancestors count"
fi
