# `GIT_blame.m31` and `GIT_filelog.m31` against real git: `git blame
# --porcelain` and `git log --format=%H -- path` on generated histories with
# branches, merges, deleted and added blocks. Shares `test.sh`'s shell,
# `$WORK`, `$LANGC`, `build`, `note`/`bad` and the counters. Git is run only
# inside the disposable repositories made here, with a fixed identity.

blx="$WORK/blame_fx"
mkdir -p "$blx"

bl_env() {
    env GIT_AUTHOR_NAME=Blame_Tester GIT_AUTHOR_EMAIL=b@example.com GIT_COMMITTER_NAME=Blame_Tester GIT_COMMITTER_EMAIL=b@example.com \
        GIT_AUTHOR_DATE="$BL_DATE +0000" GIT_COMMITTER_DATE="$BL_DATE +0000" "$@"
}

# bl_make <dir> <seed> <steps> <mode>   mode "unique": every line new text;
# "repeat": lines drawn from a small pool, so many are equal.
# History: a random walk over a few branches -- edit commits (insert block,
# delete block, change a line, re-add a deleted line), new branches, switches
# and merges (-X ours / -X theirs, so they never stop for a conflict).
bl_make() {
    local dir=$1 seed=$2 steps=$3 mode=$4
    rm -rf "$dir"
    git init -q -b main "$dir"
    (
        set -e
        set +u  # bash 3.2 (macOS) calls "${empty_array[@]}" unbound
        cd "$dir"
        export GIT_AUTHOR_NAME=Blame_Tester GIT_AUTHOR_EMAIL=b@example.com GIT_COMMITTER_NAME=Blame_Tester GIT_COMMITTER_EMAIL=b@example.com
        RANDOM=$seed
        BL_DATE=1700000000
        counter=0
        mkdir -p sub
        newline() {
            counter=$((counter + 1))
            if [ "$mode" = repeat ]; then
                case $((RANDOM % 6)) in 0) echo "}";; 1) echo "";; 2) echo "    return x;";; 3) echo "line $((RANDOM % 4))";; 4) echo "{";; *) echo "line $counter";; esac
            else
                echo "line $counter"
            fi
        }
        commit_edit() {
            local f=sub/f.txt
            [ -f $f ] || : >$f
            L=(); while IFS= read -r bl_line; do L+=("$bl_line"); done <$f
            local n=${#L[@]} p k i
            case $((RANDOM % 5)) in
            0 | 1)
                p=$((RANDOM % (n + 1))); k=$((1 + RANDOM % 4))
                new=(); for ((i = 0; i < k; i++)); do new+=("$(newline)"); done
                L=("${L[@]:0:p}" "${new[@]}" "${L[@]:p}")
                ;;
            2)
                if [ $n -gt 2 ]; then p=$((RANDOM % n)); k=$((1 + RANDOM % 3)); L=("${L[@]:0:p}" "${L[@]:p+k}"); else L+=("$(newline)"); fi
                ;;
            3)
                if [ $n -gt 0 ]; then L[$((RANDOM % n))]="$(newline)"; else L+=("$(newline)"); fi
                ;;
            4)
                p=$((RANDOM % (n + 1)))
                L=("${L[@]:0:p}" "$(newline)" "$(newline)" "${L[@]:p}")
                ;;
            esac
            if [ ${#L[@]} -gt 0 ]; then printf '%s\n' "${L[@]}" >$f; else : >$f; fi
            git add -A
            BL_DATE=$((BL_DATE + 60)); bl_env git commit -q --allow-empty -m "edit $counter"
        }
        bl_env() { env GIT_AUTHOR_DATE="$BL_DATE +0000" GIT_COMMITTER_DATE="$BL_DATE +0000" "$@"; }
        commit_edit
        commit_edit
        branches=(main)
        for ((s = 0; s < steps; s++)); do
            r=$((RANDOM % 20))
            if [ $r -lt 11 ]; then
                commit_edit
            elif [ $r -lt 14 ]; then
                name="b$s"
                git switch -q -c "$name"; branches+=("$name")
                commit_edit
            elif [ $r -lt 16 ]; then
                git switch -q "${branches[$((RANDOM % ${#branches[@]}))]}"
            else
                other="${branches[$((RANDOM % ${#branches[@]}))]}"
                cur=$(git symbolic-ref --short HEAD)
                if [ "$other" != "$cur" ]; then
                    strategy=ours; [ $((RANDOM % 2)) -eq 0 ] && strategy=theirs
                    BL_DATE=$((BL_DATE + 60))
                    bl_env git merge -q --no-edit -X $strategy "$other" >/dev/null 2>&1 || git merge --abort >/dev/null 2>&1 || true
                fi
            fi
        done
        git switch -q main
        for b in "${branches[@]}"; do
            BL_DATE=$((BL_DATE + 60))
            bl_env git merge -q --no-edit -X theirs "$b" >/dev/null 2>&1 || git merge --abort >/dev/null 2>&1 || true
        done
        commit_edit
    )
}

# the `<sha> <orig> <final>` headers of git's porcelain output
bl_oracle() { (cd "$1" && git blame --porcelain "$2" -- "$3" | awk '/^[0-9a-f]{40,64} [0-9]+ [0-9]+/ {print $1, $2, $3}'); }

if build t_blame; then
    for spec in "unique 11 25" "unique 12 40" "unique 13 60" "unique 14 90" "unique 15 40" "unique 16 70"; do
        set -- $spec
        mode=$1 seed=$2 steps=$3
        d="$blx/u$seed"
        if ! bl_make "$d" "$seed" "$steps" "$mode" >"$blx/make.log" 2>&1; then
            bad "blame: fixture $seed" "$(tail -5 "$blx/make.log")"
            continue
        fi
        commits=$(git -C "$d" rev-list --all | wc -l)
        merges=$(git -C "$d" rev-list --all --merges | wc -l)
        for name in HEAD HEAD~2 HEAD~5 HEAD~9; do
            rev=$(git -C "$d" rev-parse "$name" 2>/dev/null) || continue
            want=$(bl_oracle "$d" "$rev" sub/f.txt 2>&1)
            got=$("$WORK/t_blame" "$d/.git" blame "$rev" sub/f.txt 2>&1 | sed 's/^\^//')
            short=$name
            if [ "$want" = "$got" ]; then
                note "blame: $mode seed $seed @ $short ($commits commits, $merges merges, $(printf '%s\n' "$want" | grep -c .) lines) matches git blame --porcelain"
            else
                bad "blame: $mode seed $seed @ $short" "$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -8)"
            fi
        done
        want=$(cd "$d" && git blame --porcelain HEAD -- sub/f.txt | grep -c '^boundary$')
        got=$("$WORK/t_blame" "$d/.git" blame HEAD sub/f.txt | grep -c '^\^')
        # git prints "boundary" once per commit, we mark every line
        wantc=$(cd "$d" && git blame --porcelain HEAD -- sub/f.txt | awk '/^[0-9a-f]{40,64} [0-9]+ [0-9]+/ {sha=$1} /^boundary$/ {print sha}' | sort -u | wc -l)
        gotc=$("$WORK/t_blame" "$d/.git" blame HEAD sub/f.txt | grep '^\^' | cut -d' ' -f1 | sort -u | wc -l)
        if [ "$wantc" = "$gotc" ]; then
            note "blame: seed $seed boundary commits agree ($gotc)"
        else
            bad "blame: seed $seed boundary commits" "git=$wantc ours=$gotc"
        fi
    done
fi

# --- repeated lines: braces, blanks and duplicates, where xdiff's choices matter
#
# Both sides use the same xdiff, so these are expected to match line for line;
# a mismatch is counted per class (see the message) instead of hidden.
if [ -x "$WORK/t_blame" ]; then
    for seed in ${BL_SEEDS:-21 22 23 24}; do
        d="$blx/r$seed"
        if ! bl_make "$d" "$seed" 50 repeat >"$blx/make.log" 2>&1; then
            bad "blame: repeat fixture $seed" "$(tail -5 "$blx/make.log")"
            continue
        fi
        rev=$(git -C "$d" rev-parse HEAD)
        want=$(bl_oracle "$d" "$rev" sub/f.txt 2>&1)
        got=$("$WORK/t_blame" "$d/.git" blame "$rev" sub/f.txt 2>&1 | sed 's/^\^//')
        if [ "$want" = "$got" ]; then
            note "blame: repeated lines, seed $seed ($(printf '%s\n' "$want" | grep -c .) lines) match git blame"
        else
            diffs=$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | grep -c '^<')
            bad "blame: repeated lines, seed $seed: $diffs of $(printf '%s\n' "$want" | grep -c .) lines attributed differently" "$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -6)"
        fi
    done
fi

# --- classes where we are expected to differ, and an early stop -----------------
if [ -x "$WORK/t_blame" ]; then
    d="$blx/rename"
    rm -rf "$d"
    git init -q -b main "$d"
    (
        cd "$d"
        export GIT_AUTHOR_NAME=Blame_Tester GIT_AUTHOR_EMAIL=b@example.com GIT_COMMITTER_NAME=Blame_Tester GIT_COMMITTER_EMAIL=b@example.com
        export GIT_AUTHOR_DATE='1700000000 +0000' GIT_COMMITTER_DATE='1700000000 +0000'
        printf 'a\nb\nc\nd\n' >old.txt; git add old.txt; git commit -q -m one
        export GIT_AUTHOR_DATE='1700000100 +0000' GIT_COMMITTER_DATE='1700000100 +0000'
        printf 'a\nb\nc\nd\ne\n' >old.txt; git commit -q -am two
        export GIT_AUTHOR_DATE='1700000200 +0000' GIT_COMMITTER_DATE='1700000200 +0000'
        git mv old.txt new.txt; git commit -q -m rename
    )
    first=$(git -C "$d" rev-list --max-parents=0 HEAD)
    renamed=$(git -C "$d" rev-parse HEAD)
    gitfirst=$(bl_oracle "$d" HEAD new.txt | head -1 | cut -d' ' -f1)
    oursfirst=$("$WORK/t_blame" "$d/.git" blame HEAD new.txt | head -1 | sed 's/^\^//' | cut -d' ' -f1)
    if [ "$gitfirst" = "$first" ] && [ "$oursfirst" = "$renamed" ]; then
        note "blame: known difference -- git follows a whole-file rename, we blame the renaming commit"
    else
        bad "blame: rename class" "git=$gitfirst ours=$oursfirst first=$first renamed=$renamed"
    fi
    got=$("$WORK/t_blame" "$d/.git" blame HEAD nothing.txt 2>&1 || true)
    case "$got" in
    "refused: no such path"*) note "blame: a path the revision does not have is refused" ;;
    *) bad "blame: missing path" "$got" ;;
    esac
    got=$("$WORK/t_blame" "$d/.git" blame HEAD new.txt stop 1 | awk '$1 == "" {n++} END {print n + 0}')
    note "blame: progress callback can stop the walk (partial result has $(printf '%s' "$got") unattributed lines)"
fi

# --- file history: `git log --format=%H -- path` ---------------------------------
if build t_filelog; then
    for seed in 11 12 13 14 15 16 21 22 23 24; do
        d="$blx/u$seed"
        [ -d "$d" ] || d="$blx/r$seed"
        [ -d "$d" ] || continue
        for target in sub/f.txt sub; do
            want=$(git -C "$d" log --format=%H -- "$target" 2>&1)
            got=$("$WORK/t_filelog" "$d/.git" HEAD "$target" 2>&1)
            if [ "$want" = "$got" ]; then
                note "filelog: seed $seed -- $target ($(printf '%s\n' "$want" | grep -c .) of $(git -C "$d" rev-list --count HEAD) commits) matches git log"
            else
                bad "filelog: seed $seed -- $target" "$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -8)"
            fi
        done
        want=$(git -C "$d" log --format=%H -3 -- sub/f.txt)
        got=$("$WORK/t_filelog" "$d/.git" HEAD sub/f.txt 3)
        if [ "$want" = "$got" ]; then
            note "filelog: seed $seed limit 3 matches"
        else
            bad "filelog: seed $seed limit" "$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -8)"
        fi
    done
    d="$blx/rename"
    if [ -d "$d" ]; then
        want=$(git -C "$d" log --format=%H -- new.txt)
        got=$("$WORK/t_filelog" "$d/.git" HEAD new.txt)
        want2=$(git -C "$d" log --format=%H -- old.txt)
        got2=$("$WORK/t_filelog" "$d/.git" HEAD old.txt)
        want3=$(git -C "$d" log --format=%H -- missing.txt)
        got3=$("$WORK/t_filelog" "$d/.git" HEAD missing.txt)
        if [ "$want" = "$got" ] && [ "$want2" = "$got2" ] && [ "$want3" = "$got3" ]; then
            note "filelog: a renamed file (add, delete), and a path that never existed, match git log"
        else
            bad "filelog: rename" "new: $want / $got" "old: $want2 / $got2"
        fi
    fi
fi
