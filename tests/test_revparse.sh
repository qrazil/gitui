# `GIT_revparse.m31` -- git's revision grammar -- against real `git rev-parse`.
# The fixture (`rp_fixture.sh`) is a history with merges, a criss-cross, tags of
# every kind, clashing names, upstreams, a reflog, a stash, packed and loose
# objects and a conflicted index; `oracles/revparse_exprs.py` draws a few
# thousand expressions from the names that are really in it (abbreviations of
# every length included); `oracles/revparse_oracle.py` asks git. A form the
# module refuses as unsupported is skipped by the comparison but counted, and
# the count is held below a tenth, so "refuse everything" cannot pass. Shares
# `test.sh`'s shell, `$WORK`, `$LANGC`, `build`, `note`/`bad` and the counters.

. tests/rp_fixture.sh

rpx="$WORK/revparse_fx"
mkdir -p "$rpx"
# The formats the fixture is built in; the SHA-256 half is added by the
# SHA-256 checks, which need the object format to be understood everywhere.
RP_FORMATS=${RP_FORMATS:-sha1}

# git as the fixture saw it: no user or system configuration
rp_env() { env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$@"; }

# rp_compare <label> <fixture> <our mode> <oracle mode> <file> [<oracle file>]
# -- one expression per line; git is asked the lines of <oracle file> instead
# when it is given (the same expressions with something added)
rp_compare() {
    local label=$1 fx=$2 mode=$3 omode=$4 file=$5 ofile=${6:-$5} n differ skipped
    rp_env python3 tests/oracles/revparse_oracle.py "$fx/work" "$omode" "$ofile" >"$file.want" 2>"$file.oerr"
    rp_env "$WORK/t_revparse" "$fx/work/.git" "$mode" "$file" 2>"$file.err" |
        sed -e 's/^err .*/err/' -e 's/^unsupported .*/unsupported/' >"$file.got"
    n=$(wc -l <"$file" | tr -d ' ')
    differ=$(paste -d'\t' "$file" "$file.want" "$file.got" | awk -F'\t' '$3 != "unsupported" && $2 != $3' | wc -l | tr -d ' ')
    skipped=$(awk '$0 == "unsupported"' "$file.got" | wc -l | tr -d ' ')
    if [ "$n" -lt 100 ] || [ "$(wc -l <"$file.got" | tr -d ' ')" != "$n" ]; then
        bad "revparse: $label" "expressions: $n; answers: $(wc -l <"$file.got" | tr -d ' ')" "$(head -3 "$file.err")" "$(head -3 "$file.oerr")"
    elif [ "$differ" != 0 ]; then
        bad "revparse: $label ($differ of $n differ)" "$(paste -d'\t' "$file" "$file.want" "$file.got" |
            awk -F'\t' '$3 != "unsupported" && $2 != $3 {print $1 "\n   git:  " $2 "\n   ours: " $3}' | head -24)"
    elif [ $((skipped * 10)) -gt "$n" ]; then
        bad "revparse: $label refused $skipped of $n as unsupported"
    else
        note "revparse: $label: $n expressions match git ($skipped unsupported forms skipped)"
    fi
}

# rp_suffix <file> <suffix> -- the lines of the file with the suffix appended, but
# not those with a `:` in them (`:/re^{tree}` and `rev:path^{tree}` take the suffix
# into the pattern or the path) or an `@{` (when the part before the suffix does
# not resolve, git reads the whole text as a reflog date and answers with
# whatever `approxidate` makes of it, which the module refuses as unsupported)
rp_suffix() { awk -v s="$2" 'index($0, ":") == 0 && index($0, "@{") == 0 {print $0 s}' "$1"; }
# rp_plain <file> -- the same lines without the suffix
rp_plain() { awk 'index($0, ":") == 0 && index($0, "@{") == 0' "$1"; }

if build t_revparse; then
    for fmt in $RP_FORMATS; do
        fx="$rpx/$fmt"
        if ! rp_fixture "$fx" "$fmt" >"$rpx/fixture-$fmt.log" 2>&1; then
            bad "revparse: $fmt fixture" "$(tail -5 "$rpx/fixture-$fmt.log")"
            continue
        fi
        if [ -n "$(rp_env git -C "$fx/work" fsck --strict 2>&1 | grep -v '^dangling\|^Checking\|^notice')" ]; then
            bad "revparse: $fmt fixture is not fsck-clean" "$(rp_env git -C "$fx/work" fsck --strict 2>&1 | head -5)"
        else
            note "revparse: $fmt fixture built, $(rp_env git -C "$fx/work" rev-list --all --count) commits, git fsck --strict is clean"
        fi
        for seed in 1 2; do
            python3 tests/oracles/revparse_exprs.py "$fx/work" "$seed" 700 all >"$rpx/$fmt-all$seed.txt"
            python3 tests/oracles/revparse_exprs.py "$fx/work" "$seed" 700 plain >"$rpx/$fmt-plain$seed.txt"
            rp_suffix "$rpx/$fmt-plain$seed.txt" '^{commit}' >"$rpx/$fmt-commit$seed.txt"
            rp_suffix "$rpx/$fmt-plain$seed.txt" '^{tree}' >"$rpx/$fmt-tree$seed.txt"
            rp_compare "$fmt seed $seed, rev-parse lines (ranges, ^, ^@, ^!)" "$fx" lines lines "$rpx/$fmt-all$seed.txt"
            rp_compare "$fmt seed $seed, rev-parse --verify" "$fx" object object "$rpx/$fmt-plain$seed.txt"
            rp_plain "$rpx/$fmt-plain$seed.txt" >"$rpx/$fmt-nocolon$seed.txt"
            rp_compare "$fmt seed $seed, commit_id = <rev>^{commit}" "$fx" commit object "$rpx/$fmt-nocolon$seed.txt" "$rpx/$fmt-commit$seed.txt"
            rp_compare "$fmt seed $seed, tree_id = <rev>^{tree}" "$fx" tree object "$rpx/$fmt-nocolon$seed.txt" "$rpx/$fmt-tree$seed.txt"
        done
    done
fi

# --- the callers: a spelling of a revision and the id git gives it do the same --------------------
#
# Each engine that takes a revision is asked once with the grammar's spelling
# and once with the full id `git rev-parse` prints for it; the answers must be
# the same. The spelling is checked against git above, so this checks the wiring.

rpc_fmt=${RP_FORMATS%% *}
rpc="$rpx/$rpc_fmt"
if [ -d "$rpc/work" ] && build t_revparse && build t_blame && build t_filelog && build git; then
    rpc_git() { rp_env git -C "$rpc/work" "$@"; }
    for spec in 'master~3' 'v1~1' 'feature^{/f1}' 'origin/feature^' 'HEAD@{2}' ':/c4' 'tiea^2~1'; do
        id=$(rpc_git rev-parse --verify -q "$spec" 2>/dev/null)
        id=$(rpc_git rev-parse --verify -q "$id^{commit}")
        a=$(rp_env "$WORK/t_blame" "$rpc/work/.git" blame "$spec" a.txt 2>&1)
        b=$(rp_env "$WORK/t_blame" "$rpc/work/.git" blame "$id" a.txt 2>&1)
        if [ -n "$a" ] && [ "$a" = "$b" ]; then
            note "revparse callers: blame at $spec = blame at its id ($(printf '%s\n' "$a" | wc -l | tr -d ' ') lines)"
        else
            bad "revparse callers: blame at $spec" "spelling: $(printf '%s\n' "$a" | head -3)" "id: $(printf '%s\n' "$b" | head -3)"
        fi
        a=$(rp_env "$WORK/t_filelog" "$rpc/work/.git" "$spec" a.txt 2>&1)
        b=$(rp_env "$WORK/t_filelog" "$rpc/work/.git" "$id" a.txt 2>&1)
        want=$(rpc_git log --format=%H "$id" -- a.txt)
        if [ -n "$a" ] && [ "$a" = "$b" ] && [ "$a" = "$want" ]; then
            note "revparse callers: file history at $spec = git log of its id ($(printf '%s\n' "$a" | wc -l | tr -d ' ') commits)"
        else
            bad "revparse callers: file history at $spec" "spelling: $(printf '%s\n' "$a" | head -3)" "id: $(printf '%s\n' "$b" | head -3)" "git: $(printf '%s\n' "$want" | head -3)"
        fi
        a=$(rp_env "$WORK/git" --git-dir "$rpc/work/.git" -log --max 8 "$spec" 2>&1 | grep '^commit ')
        want=$(rpc_git log --max-count=8 --format='commit %H' "$id")
        if [ -n "$a" ] && [ "$a" = "$want" ]; then
            note "revparse callers: -log $spec lists git log's commits ($(printf '%s\n' "$a" | wc -l | tr -d ' '))"
        else
            bad "revparse callers: -log $spec" "ours: $(printf '%s\n' "$a" | head -3)" "git: $(printf '%s\n' "$want" | head -3)"
        fi
    done
    # the command-line plumbing against git's: what it prints for each spelling
    for spec in 'HEAD~2' 'master^{tree}' 'v1:a.txt' 'master~5^2' 'origin/master' 'first..master~1' 'master...feature' '^side' 'ca^@' 'ca^!' '@{-1}' 'master@{upstream}' 'synth@{1700000065}' ':/second'; do
        want=$(rpc_git rev-parse "$spec" 2>/dev/null)
        got=$(rp_env "$WORK/git" --git-dir "$rpc/work/.git" -rev-parse "$spec" 2>/dev/null)
        if [ "$want" = "$got" ]; then
            note "revparse callers: -rev-parse $spec"
        else
            bad "revparse callers: -rev-parse $spec" "git: $want" "ours: $got"
        fi
    done
    for spec in 'master' 'v1' 'v1^{tree}' 'master~2:dir' 'HEAD:dir/sub' 'master^{/c3}^{tree}'; do
        want=$(rpc_git ls-tree "$spec" 2>/dev/null)
        got=$(rp_env "$WORK/git" --git-dir "$rpc/work/.git" -ls-tree "$spec" 2>/dev/null)
        if [ "$want" = "$got" ]; then
            note "revparse callers: -ls-tree $spec ($(printf '%s\n' "$want" | wc -l | tr -d ' ') entries)"
        else
            bad "revparse callers: -ls-tree $spec" "git: $(printf '%s\n' "$want" | head -3)" "ours: $(printf '%s\n' "$got" | head -3)"
        fi
    done
    for spec in 'v1' 'v1^{tree}' 'master:a.txt' 'HEAD~1^{commit}'; do
        want=$(rpc_git cat-file -t "$spec" 2>/dev/null)
        got=$(rp_env "$WORK/git" --git-dir "$rpc/work/.git" -cat-file --type "$spec" 2>/dev/null)
        [ "$want" = "$got" ] && note "revparse callers: -cat-file --type $spec ($want)" || bad "revparse callers: -cat-file --type $spec" "git: $want" "ours: $got"
    done

    # what the module refuses to do is said so, and nothing is guessed
    rp_refuses() {
        local spec=$1 pattern=$2 err rc
        err=$(rp_env "$WORK/git" --git-dir "$rpc/work/.git" -rev-parse "$spec" 2>&1 >/dev/null); rc=$?
        if [ $rc -ne 0 ] && printf '%s' "$err" | grep -q "$pattern"; then
            note "revparse: $spec is refused with a reason ($pattern)"
        else
            bad "revparse: $spec should be refused as '$pattern'" "rc=$rc: $err"
        fi
    }
    rp_refuses '@{yesterday}' 'Unix time'
    rp_refuses 'master@{2.days.ago}' 'Unix time'
    rp_refuses ':/\<c' 'cannot translate'
    rp_refuses ':/(a)\1' 'cannot translate'
    rp_refuses 'master^{/a**}' 'cannot translate'
    rp_refuses 'master^{/[[=a=]]}' 'cannot translate'
    rp_refuses 'master^{/(a}' 'not a valid regular expression'
    rp_refuses 'nosuchname' 'unknown revision'
    rp_refuses 'master~99' 'no such parent'
    rp_refuses 'master:nosuchpath' 'no such path'
    rp_refuses 'master^{blob}' 'does not peel'
    rp_refuses ':3:nosuchpath' 'not in the index\|no such path in the index'
    rp_refuses '' 'empty'
    # a wrong answer would be worse than none: nothing above resolves quietly
    for spec in '@{yesterday}' ':/\<c' 'master@{2.days.ago}'; do
        out=$(rp_env "$WORK/git" --git-dir "$rpc/work/.git" -rev-parse "$spec" 2>/dev/null)
        [ -z "$out" ] && note "revparse: $spec prints no object name" || bad "revparse: $spec printed $out"
    done
fi

# merge takes a spelling too: `git merge origin/side~1` and ours leave the same tree and parents
if [ -d "$rpc/work" ] && build t_merge; then
    rpm_env() { env GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com \
        GIT_AUTHOR_DATE='1700000000 +0000' GIT_COMMITTER_DATE='1700000000 +0000' GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$@"; }
    for spec in 'origin/side~1' 'origin/feature^' 'v1~1' ':/c4' 'feature^{/f1}'; do
        for who in git ours; do
            d="$rpx/merge-$who"
            rm -rf "$d"
            git clone -q "$rpc/work" "$d" 2>/dev/null
            git -C "$d" checkout -q -b mrg light 2>/dev/null
        done
        rpm_env git -C "$rpx/merge-git" merge -q --no-ff -m "merge $spec" "$spec" >/dev/null 2>&1
        rpm_env "$WORK/t_merge" "$rpx/merge-ours/.git" "$rpx/merge-ours" merge "$spec" --no-ff >"$rpx/merge-ours.out" 2>&1
        want="$(git -C "$rpx/merge-git" rev-parse 'HEAD^{tree}') $(git -C "$rpx/merge-git" rev-list --parents -1 HEAD | wc -w | tr -d ' ') $(git -C "$rpx/merge-git" rev-parse 'HEAD^2' 2>/dev/null)"
        got="$(git -C "$rpx/merge-ours" rev-parse 'HEAD^{tree}') $(git -C "$rpx/merge-ours" rev-list --parents -1 HEAD | wc -w | tr -d ' ') $(git -C "$rpx/merge-ours" rev-parse 'HEAD^2' 2>/dev/null)"
        if [ "$want" = "$got" ]; then
            note "revparse callers: merge $spec leaves git's tree and second parent"
        else
            bad "revparse callers: merge $spec" "git:  $want" "ours: $got" "$(head -3 "$rpx/merge-ours.out")"
        fi
    done
fi
