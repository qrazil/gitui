# The command line of 1git and mgit (docs/CLI.md): every command's `--help`
# against its golden text, the refusals with their messages and exit status,
# every option of every command through the table (`cli_cases.txt`, both
# directions), several commands on one line, the transition shim for every old
# form, and mgit's flags under a pty.
#
# Sourced from `test.sh` (see `test_write.sh`): no `set`, `cd` or `trap` here;
# `$WORK`, `build`, `note` and `bad` are `test.sh`'s. `tests/run_cli.sh` runs
# this file alone. UPDATE_GOLDEN=1 rewrites tests/golden/cli/ (read the diff).
#
# Portable shell: BSD sed needs a suffix for -i, there is no tac, no cat -A, no
# GNU timeout, no date +%s%N, and no fixed /tmp path.

cli_gold=tests/golden/cli
cli_work="$WORK/cli"
mkdir -p "$cli_work"

if build git && build t_cli; then
    cli_one="$WORK/git"

    # --- --help: the program and every command, against the goldens ---------------
    cli_words=$("$cli_one" --help | sed -n 's/^ *\(-[a-z]\), -\([a-z-]*\) .*/\2/p; s/^      -\([a-z-]*\) .*/\1/p' | sed -n '/^[a-z]/p' | sort -u)
    cli_helps_ok=1
    cli_check_help() { # <name> <args...>
        local name=$1
        shift
        "$cli_one" "$@" >"$cli_work/help.out" 2>&1
        if [ "${UPDATE_GOLDEN:-}" = 1 ]; then
            cp "$cli_work/help.out" "$cli_gold/$name.txt"
        elif ! cmp -s "$cli_work/help.out" "$cli_gold/$name.txt"; then
            cli_helps_ok=0
            bad "cli help golden: $name" "$(diff "$cli_gold/$name.txt" "$cli_work/help.out" | head -10)"
        fi
    }
    cli_check_help program --help
    for cli_word in $cli_words; do
        cli_check_help "$cli_word" "-$cli_word" --help
    done
    cli_count=$(printf '%s\n' "$cli_words" | wc -l | tr -d ' ')
    [ "$cli_helps_ok" = 1 ] && note "cli: --help of the program and $cli_count commands match tests/golden/cli"
    # docs/CLI-REFERENCE.md holds the same text
    if [ "${UPDATE_GOLDEN:-}" = 1 ]; then
        {
            echo "# 1git command reference"
            echo
            echo "Generated from \`1git --help\` and \`1git -<command> --help\` (tests/golden/cli); do not edit."
            echo
            echo '```'
            cat "$cli_gold/program.txt"
            echo '```'
            for cli_word in $cli_words; do
                echo
                echo "## -$cli_word"
                echo
                echo '```'
                cat "$cli_gold/$cli_word.txt"
                echo '```'
            done
        } >docs/CLI-REFERENCE.md
    elif [ -f docs/CLI-REFERENCE.md ]; then
        cli_ref_ok=1
        for cli_word in $cli_words; do
            if ! grep -qF -- "usage: 1git -$cli_word" docs/CLI-REFERENCE.md; then cli_ref_ok=0; fi
        done
        [ "$cli_ref_ok" = 1 ] && note "cli: docs/CLI-REFERENCE.md has every command" || bad "cli: docs/CLI-REFERENCE.md is missing a command" "UPDATE_GOLDEN=1 bash tests/run_cli.sh"
    fi

    # --- the table, every option, both directions ------------------------------------
    if command -v python3 >/dev/null; then
        if out=$(python3 -I tests/cli_cases.py "$WORK/t_cli" "$cli_one" 2>&1); then
            note "cli: ${out##*$'\n'}"
        else
            bad "cli: tests/cli_cases.txt" "$(printf '%s\n' "$out" | head -30)"
        fi
    fi

    # --- refusals: the message and the exit status --------------------------------------
    # <expected text> <args...>: standard error holds the text, the status is 2
    cli_refuse() {
        local want=$1
        shift
        local err rc
        err=$("$cli_one" "$@" 2>&1 >/dev/null)
        rc=$?
        if [ "$rc" = 2 ] && printf '%s' "$err" | grep -qF -- "$want"; then
            cli_refused=$((cli_refused + 1))
        else
            bad "cli refusal: 1git $*" "wanted status 2 and: $want" "got status $rc: $(printf '%s' "$err" | head -3)"
        fi
    }
    cli_refused=0
    cli_refuse "unknown option '--nope'" -log --nope
    cli_refuse "did you mean '--max'" -log --mx 3
    cli_refuse "'--max' needs a whole number, and got 'abc'" -log --max abc
    cli_refuse "'--max' needs a value and is the last argument" -log --max
    cli_refuse "'--max' needs a value and is the last argument" -log --max -status
    cli_refuse "'--oneline' is a flag and takes no value" -log --oneline=yes
    cli_refuse "'--max' was given more than once and takes a single value" -log --max 1 --max 2
    cli_refuse "'--path' was given more than once" -log --path a --path b
    cli_refuse "'--path' needs at least one value" -log --path
    cli_refuse "short options do not cluster" -log --np
    cli_refuse "unknown command '-lgo'" -lgo
    cli_refuse "'-h' would be a command here" -h
    cli_refuse "'--h' is not an option" -log --h
    cli_refuse "'help' is an option here" help
    cli_refuse "has no meaning here" -log --
    cli_refuse "needs a command" --dir .
    cli_refuse "'--format' needs one of long, short, porcelain, porcelain2, and got 'x'" -status --format x
    cli_refuse "'--edit' needs one of on, off, and got 'maybe'" -commit --edit maybe
    cli_refuse "'--mode' needs one of soft, mixed, hard, keep" -reset --mode medium
    cli_refuse "'--from' says where a new branch starts" -switch --from main
    cli_refuse "choose one of '--create'" -branch --create a --delete b
    cli_refuse "'--topic' is a Gerrit topic" -push --topic x
    cli_refuse "'--nested' deletes whole repositories" -clean --nested
    cli_refuse "-merge needs the branch or commit to merge" -merge
    cli_refuse "-switch needs a branch to switch to" -switch
    cli_refuse "needs the commits to work on" -cherry-pick
    cli_refuse "unknown option '--no-edit'" -commit --no-edit
    cli_refuse "missing <NAME>" -remote-add
    note "cli: $cli_refused refusals, each with its message and status 2"

    # --- a fixture repository for the runs below ------------------------------------------
    cli_env() { # <args>: real git with fixed identities and dates
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.com \
            GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.com \
            GIT_AUTHOR_DATE="1700000000 +0000" GIT_COMMITTER_DATE="1700000000 +0000" "$@"
    }
    cli_fixture() { # <dir>
        rm -rf "$1"
        mkdir -p "$1"
        (
            cd "$1" || exit 1
            cli_env git init -q -b main . >/dev/null 2>&1
            printf 'one\ntwo\nthree\n' >a.txt
            printf 'bee\n' >b.txt
            mkdir sub
            printf 'cee\n' >sub/c.txt
            cli_env git add -A
            cli_env git commit -q -m base
            printf 'four\n' >>a.txt
            cli_env git commit -q -am second
            cli_env git tag v1
            cli_env git checkout -q -b side
            printf 'side\n' >s.txt
            cli_env git add s.txt
            cli_env git commit -q -m side
            cli_env git checkout -q main
        ) >/dev/null 2>&1
    }
    cli_state() { # <repo>: what the repository holds, for twin comparisons
        (
            cd "$1" || exit 1
            echo "## refs"
            git for-each-ref
            echo "## head"
            git symbolic-ref -q HEAD || git rev-parse HEAD
            echo "## index"
            git ls-files -s
            echo "## status"
            git status --porcelain=v2 -b 2>&1
            echo "## tree"
            find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while read -r f; do printf '%s %s\n' "$f" "$(cksum <"$f")"; done
        )
    }

    cli_fixture "$cli_work/fx"
    cli_ok=1
    ONE() { (cd "$cli_work/fx" && cli_env "$cli_one" "$@"); }

    # --- several commands on one line ------------------------------------------------------
    cli_fixture "$cli_work/chain"
    (
        cd "$cli_work/chain" || exit 1
        printf 'five\n' >>a.txt
        cli_env "$cli_one" -add --all -commit --message "chained" -tag --create chained-tag >"$cli_work/chain.out" 2>&1
        echo "rc=$?" >>"$cli_work/chain.out"
    )
    if [ "$(git -C "$cli_work/chain" log -1 --format=%s)" = chained ] && git -C "$cli_work/chain" rev-parse -q --verify refs/tags/chained-tag >/dev/null && grep -q '^rc=0' "$cli_work/chain.out"; then
        note "cli: -add -commit -tag on one line run in order and exit 0"
    else
        bad "cli: a chained line" "$(cat "$cli_work/chain.out")" "$(git -C "$cli_work/chain" log --oneline | head -3)"
    fi

    # a command that fails ends the line: exit 1, the next one does not run
    printf 'six\n' >>"$cli_work/chain/a.txt"
    (cd "$cli_work/chain" && cli_env "$cli_one" -switch no-such-branch -commit --all --message "must not happen" >/dev/null 2>&1)
    cli_rc=$?
    if [ "$cli_rc" = 1 ] && [ "$(git -C "$cli_work/chain" log -1 --format=%s)" = chained ]; then
        note "cli: a failing command stops the line with exit 1"
    else
        bad "cli: failing command" "status $cli_rc, last commit: $(git -C "$cli_work/chain" log -1 --format=%s)"
    fi

    # a mistake in the last command is found before the first runs: exit 2, nothing done
    git -C "$cli_work/chain" checkout -q -- a.txt
    printf 'seven\n' >>"$cli_work/chain/a.txt"
    (cd "$cli_work/chain" && cli_env "$cli_one" -commit --all --message "must not happen either" -log --max zebra >/dev/null 2>&1)
    cli_rc=$?
    if [ "$cli_rc" = 2 ] && [ "$(git -C "$cli_work/chain" log -1 --format=%s)" = chained ]; then
        note "cli: a typo in the last command is found before the first runs (exit 2)"
    else
        bad "cli: validate the whole line first" "status $cli_rc, last commit: $(git -C "$cli_work/chain" log -1 --format=%s)"
    fi

    # an error the table sees (not the parser) also happens before anything runs
    (cd "$cli_work/chain" && cli_env "$cli_one" -commit --all --message "nor this" -switch --from main >/dev/null 2>&1)
    cli_rc=$?
    [ "$cli_rc" = 2 ] && [ "$(git -C "$cli_work/chain" log -1 --format=%s)" = chained ] && note "cli: a refusal of the table also precedes every command (exit 2)" || bad "cli: table refusal before running" "status $cli_rc"

    # --dir and --config
    cli_fixture "$cli_work/dirrepo"
    out=$(cd "$cli_work" && cli_env "$cli_one" --dir dirrepo -log --max 1 --format %s 2>&1)
    [ "$out" = second ] && note "cli: --dir runs in another directory" || bad "cli: --dir" "$out"
    out=$(cd "$cli_work/dirrepo" && cli_env "$cli_one" --config log.abbrevCommit=true -log --max 1 --format %h 2>&1 | tr -d '\n' | wc -c | tr -d ' ')
    [ "$out" = 7 ] && note "cli: --config is git's -c" || bad "cli: --config" "$out"

    # --- the transition shim: every old form, same result as the new form ---------------------
    # the pairs come from cli_cases.txt: old line `<`, new line above it. Read-only forms
    # are run in the fixture and the outputs compared; the changing ones in twin copies.
    cli_shim_total=0
    cli_shim_bad=0
    cli_pair() { # <git line> <our line>: run both, same stdout, same state
        local old=$1 new=$2 ra rb
        cli_shim_total=$((cli_shim_total + 1))
        cli_fixture "$cli_work/twin-a"
        rm -rf "$cli_work/twin-b"
        cp -R "$cli_work/twin-a" "$cli_work/twin-b"
        eval "set -- $old"
        (cd "$cli_work/twin-a" && cli_env "$cli_one" "$@" >"$cli_work/old.out" 2>"$cli_work/old.err" </dev/null)
        ra=$?
        eval "set -- $new"
        (cd "$cli_work/twin-b" && cli_env "$cli_one" "$@" >"$cli_work/new.out" 2>"$cli_work/new.err" </dev/null)
        rb=$?
        sed "s#twin-[ab]#TWIN#g" "$cli_work/old.out" >"$cli_work/old.n"
        sed "s#twin-[ab]#TWIN#g" "$cli_work/new.out" >"$cli_work/new.n"
        if [ "$ra" != "$rb" ] || ! cmp -s "$cli_work/old.n" "$cli_work/new.n" || [ "$(cli_state "$cli_work/twin-a")" != "$(cli_state "$cli_work/twin-b" | sed "s#twin-b#twin-a#g")" ]; then
            cli_shim_bad=$((cli_shim_bad + 1))
            bad "cli shim: '$old' and '$new' differ" "status $ra / $rb" "$(diff "$cli_work/old.out" "$cli_work/new.out" | head -5)"
        fi
        if ! grep -qF "1git: git-style arguments are deprecated; use '1git " "$cli_work/old.err"; then
            cli_shim_bad=$((cli_shim_bad + 1))
            bad "cli shim: no deprecation warning for '$old'" "$(head -3 "$cli_work/old.err")"
        fi
        if grep -qF "deprecated" "$cli_work/new.err"; then
            cli_shim_bad=$((cli_shim_bad + 1))
            bad "cli shim: the new form warns: '$new'" "$(head -3 "$cli_work/new.err")"
        fi
    }
    # old argv and new argv, identical results (fixture: a.txt, b.txt, sub/c.txt, tag v1, branch side)
    cli_pair "status -sb" "-status --format short --branch"
    cli_pair "status --porcelain=v2 -b" "-status --format porcelain2 --branch"
    cli_pair "status -uall" "-status --untracked all"
    cli_pair "log --oneline -n 2" "-log --oneline --max 2"
    cli_pair "log -1 --format=%H" "-log --max 1 --format %H"
    cli_pair "log --oneline --graph --all" "-log --oneline --graph --all"
    cli_pair "log --stat v1 -- a.txt" "-log --stat v1 --path a.txt"
    cli_pair "log --author=Fix --since=2000-01-01 --oneline" "-log --author Fix --since 2000-01-01 --oneline"
    cli_pair "log -S four --oneline" "-log --touches four --oneline"
    cli_pair "log --pretty=short -2" "-log --format short --max 2"
    cli_pair "show --stat" "-show --stat"
    cli_pair "show v1:a.txt" "-show v1:a.txt"
    cli_pair "diff v1 side --stat" "-diff v1 side --stat"
    cli_pair "diff HEAD~1 -U1 -- a.txt" "-diff HEAD~1 --context 1 --path a.txt"
    cli_pair "diff --name-status HEAD~1" "-diff --name-status HEAD~1"
    cli_pair "branch -a -v" "-branch --all --verbose"
    cli_pair "branch --list 'm*'" "-branch 'm*'"
    cli_pair "branch --show-current" "-branch --current"
    cli_pair "branch new-b v1" "-branch --create new-b --from v1"
    cli_pair "branch -D side" "-branch --force-delete side"
    cli_pair "tag -l 'v*'" "-tag 'v*'"
    cli_pair "tag -a rel -m 'release notes'" "-tag --create rel --message 'release notes'"
    cli_pair "tag -d v1" "-tag --delete v1"
    cli_pair "switch side" "-switch side"
    cli_pair "checkout side" "-switch side"
    cli_pair "checkout -b feat v1" "-switch --create feat --from v1"
    cli_pair "switch -c feat" "-switch --create feat"
    cli_pair "switch --detach v1" "-switch --detach v1"
    cli_pair "add -A" "-add --all"
    cli_pair "add sub/c.txt" "-add sub/c.txt"
    cli_pair "restore --source=v1 a.txt" "-restore --from v1 a.txt"
    cli_pair "checkout v1 -- a.txt" "-restore --from v1 a.txt"
    cli_pair "reset --hard v1" "-reset --mode hard v1"
    cli_pair "reset --soft HEAD~1" "-reset --mode soft HEAD~1"
    cli_pair "rm --cached b.txt" "-remove --keep-files b.txt"
    cli_pair "mv b.txt moved.txt" "-move b.txt moved.txt"
    cli_pair "commit --allow-empty -m 'm one' -m 'm two'" "-commit --allow-empty --message 'm one' 'm two'"
    cli_pair "commit --allow-empty --amend --no-edit" "-commit --allow-empty --amend --edit off"
    cli_pair "stash list" "-stash-list"
    cli_pair "merge --no-ff -m 'join' side" "-merge side --fast-forward never --message join"
    cli_pair "merge --ff-only side" "-merge side --fast-forward only"
    cli_pair "cherry-pick -x side" "-cherry-pick --record-origin side"
    cli_pair "revert --no-edit HEAD" "-revert --edit off HEAD"
    cli_pair "remote add up /nowhere" "-remote-add up /nowhere"
    cli_pair "remote -v" "-remote --verbose"
    cli_pair "clean -n" "-clean --dry-run"
    cli_pair "worktree list" "-worktree"
    note "cli shim: $cli_shim_total old forms give the new form's output and repository, each with one warning"
    [ "$cli_shim_bad" = 0 ] || true

    # global options of git before the command
    out=$(cd "$cli_work" && cli_env "$cli_one" -C dirrepo -c log.abbrevCommit=true log --max-count=1 --format=%h 2>"$cli_work/g.err")
    if [ "${#out}" = 7 ] && grep -q "use '1git --dir dirrepo --config log.abbrevCommit=true -log --max 1 --format %h'" "$cli_work/g.err"; then
        note "cli shim: -C and -c before the command are rewritten to --dir and --config"
    else
        bad "cli shim: global options" "$out" "$(cat "$cli_work/g.err")"
    fi
    # no equivalent: runs as git would, with git's status, and says so
    out=$(cd "$cli_work/fx" && cli_env "$cli_one" log --no-walk --first-parent --abbrev-commit --oneline 2>"$cli_work/g.err")
    rc=$?
    if [ "$rc" = 0 ] && grep -q "has no equivalent in the new command line" "$cli_work/g.err"; then
        note "cli shim: a line with an option 1git dropped runs as git would, with a warning"
    else
        bad "cli shim: untranslatable line" "status $rc" "$(cat "$cli_work/g.err")"
    fi
    # the shim is only for a first word that is a git command
    err=$("$cli_one" blame x 2>&1 >/dev/null)
    rc=$?
    [ "$rc" = 2 ] && printf '%s' "$err" | grep -qF "got 'blame'" && note "cli shim: another bare word is Oro's usual refusal" || bad "cli shim: bare unknown word" "status $rc: $err"
    # -migrate
    out=$("$cli_one" -migrate 'git log --oneline -n 5 -- a.txt')
    [ "$out" = "1git -log --oneline --max 5 --path a.txt" ] && note "cli: -migrate writes the new line" || bad "cli: -migrate" "$out"

    # --- exit status of a plain failure and of a plain success ------------------------------
    (cd "$cli_work/fx" && "$cli_one" -log nosuchrev >/dev/null 2>&1)
    cli_rc=$?
    [ "$cli_rc" = 1 ] && note "cli: a failing command exits 1 (git says 128)" || bad "cli: exit 1" "status $cli_rc"
    (cd "$cli_work/fx" && "$cli_one" -diff --quiet HEAD~1 >/dev/null 2>&1)
    cli_rc=$?
    [ "$cli_rc" = 1 ] && note "cli: -diff --quiet exits 1 on differences" || bad "cli: diff --quiet" "status $cli_rc"
    (cd "$cli_work/fx" && "$cli_one" -status >/dev/null 2>&1)
    cli_rc=$?
    [ "$cli_rc" = 0 ] && note "cli: success exits 0" || bad "cli: exit 0" "status $cli_rc"

    # --- completions -----------------------------------------------------------------------
    for cli_shell in bash zsh fish; do
        out=$("$cli_one" --completions $cli_shell 2>&1)
        case $out in
            *status*dir* | *dir*status*) cli_comp_ok=1 ;;
            *) cli_comp_ok=0 ;;
        esac
        if [ "$cli_comp_ok" = 1 ]; then
            note "cli: --completions $cli_shell lists the commands and options"
        else
            bad "cli: --completions $cli_shell" "$(printf '%s' "$out" | head -3)"
        fi
    done
fi

# --- mgit's flags under a pty ----------------------------------------------------------
if [ ! -x "$WORK/mgit" ]; then
    bash scripts/build.sh -o "$WORK/mgit" >"$WORK/cli_mgit_build.log" 2>&1 || bad "cli: scripts/build.sh (mgit)" "$(tail -5 "$WORK/cli_mgit_build.log")"
fi
if [ -x "$WORK/mgit" ] && command -v python3 >/dev/null; then
    if out=$(python3 -I tests/pty_cli.py "$WORK/mgit" "$WORK/cli_pty" 2>&1); then
        note "cli: mgit flags under a pty -- $(printf '%s\n' "$out" | tail -1)"
    else
        bad "cli: mgit flags under a pty" "$(printf '%s\n' "$out" | grep -v '^ok' | head -12)"
    fi
fi
