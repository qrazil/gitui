#!/usr/bin/env bash
# The side-by-side diff: the layout engine (`diff/GIT_sbs*.m31`), the mgit view
# (`ui/GIT_ui_sbs.m31`) and `1git diff --side-by-side`.
#
#   engine goldens   every fixture of `oracles/sbs_fixtures.py` laid out at fixed
#                    widths, the plain text compared with `tests/golden/sbs/`
#                    (UPDATE_GOLDEN=1 rewrites them; read the diff before committing)
#   properties       on random file pairs, in every mode: the left side's lines are
#                    the old file's, the right side's the new file's, line numbers
#                    strictly increase and are complete when the whole file is shown,
#                    and every visual row is exactly the plan's width
#   buffer           the pane drawn into a `TUI_buffer.Buffer` says what the engine
#                    says, and the escape sequences it sends at 16, 256 and true
#                    colour are goldens
#   text             real `git diff` output of renames, mode changes, binary files,
#                    a symlink, a submodule, CRLF, a merge conflict (combined diff
#                    stays unified) laid out side by side
#   1git             `--side-by-side`/`-y`/`--width` against that, and the bytes of
#                    `1git diff` without the flag against git's
#   pty              `pty_sbs.py` drives mgit: toggle, 120-column auto, fallback,
#                    resize, staging from both sides, the wheel and a click
#
# Sourced from `test.sh` (see `test_write.sh`): no `set`, `cd` or `trap` here;
# `$WORK`, `build`, `note` and `bad` are `test.sh`'s.

export PYTHONDONTWRITEBYTECODE=1
sbs_work="$WORK/sbs"
sbs_gold=tests/golden/sbs
mkdir -p "$sbs_work/fx" "$sbs_work/rand" "$sbs_work/out"

# compare $2 (a file) with the golden $1, or write the golden
sbs_golden() {
    local label=$1 got=$2 gold="$sbs_gold/$1"
    if [ "${UPDATE_GOLDEN:-}" = 1 ]; then
        cp "$got" "$gold"
        note "sbs golden written: $label"
    elif [ ! -f "$gold" ]; then
        bad "sbs golden missing: $label" "run with UPDATE_GOLDEN=1"
    elif cmp -s "$got" "$gold"; then
        note "sbs golden: $label"
    else
        bad "sbs golden: $label" "$(diff -u "$gold" "$got" | head -30)"
    fi
}

if build t_sbs && command -v python3 >/dev/null; then
    sbs_names=$(python3 tests/oracles/sbs_fixtures.py "$sbs_work/fx")
    sbs_bin="$WORK/t_sbs"

    # --- goldens: every fixture at 80 columns, some at other widths and modes
    for name in $sbs_names; do
        # a 45 000-column line wraps into hundreds of rows: its properties are checked below, no golden
        [ "$name" = very_long ] && continue
        "$sbs_bin" plain "$sbs_work/fx/$name.old" "$sbs_work/fx/$name.new" 80 >"$sbs_work/out/$name.80" 2>&1
        sbs_golden "$name.80.txt" "$sbs_work/out/$name.80"
    done
    for name in long_lines wide wide_wrapped tabs; do
        "$sbs_bin" plain "$sbs_work/fx/$name.old" "$sbs_work/fx/$name.new" 61 >"$sbs_work/out/$name.61" 2>&1
        sbs_golden "$name.61.txt" "$sbs_work/out/$name.61"
        "$sbs_bin" plain "$sbs_work/fx/$name.old" "$sbs_work/fx/$name.new" 61 3 scroll 9 >"$sbs_work/out/$name.scroll" 2>&1
        sbs_golden "$name.61.scroll9.txt" "$sbs_work/out/$name.scroll"
    done
    "$sbs_bin" plain "$sbs_work/fx/many_hunks.old" "$sbs_work/fx/many_hunks.new" 120 0 >"$sbs_work/out/mh0" 2>&1
    sbs_golden "many_hunks.120.context0.txt" "$sbs_work/out/mh0"
    "$sbs_bin" plain "$sbs_work/fx/many_hunks.old" "$sbs_work/fx/many_hunks.new" 120 1000000 >"$sbs_work/out/mhall" 2>&1
    sbs_golden "many_hunks.120.whole.txt" "$sbs_work/out/mhall"
    "$sbs_bin" ansi "$sbs_work/fx/intraline.old" "$sbs_work/fx/intraline.new" 80 >"$sbs_work/out/ansi" 2>&1
    sbs_golden "intraline.80.ansi.txt" "$sbs_work/out/ansi"
    "$sbs_bin" ansi "$sbs_work/fx/many_hunks.old" "$sbs_work/fx/many_hunks.new" 100 >"$sbs_work/out/ansi2" 2>&1
    sbs_golden "many_hunks.100.ansi.txt" "$sbs_work/out/ansi2"
    "$sbs_bin" plain "$sbs_work/fx/pure_add.old" "$sbs_work/fx/pure_add.new" 20 >"$sbs_work/out/narrow" 2>&1
    if [ "$(cat "$sbs_work/out/narrow")" = "too narrow" ]; then
        note "sbs: a plan with no room for the text says so (the caller falls back to unified)"
    else
        bad "sbs: too narrow a width is refused" "$(cat "$sbs_work/out/narrow")"
    fi

    # --- intra-line marks
    marks=$("$sbs_bin" marks "foo(bar, baz) = 1" "foo(bar, qux) = 1")
    if [ "$marks" = "$(printf 'old [9,12)\nnew [9,12)')" ]; then
        note "sbs marks: only the changed word"
    else
        bad "sbs marks: one changed word" "$marks"
    fi
    marks=$("$sbs_bin" marks "a b c d e" "a X c d Y")
    if [ "$marks" = "$(printf 'old [2,3) [8,9)\nnew [2,3) [8,9)')" ]; then
        note "sbs marks: two separate changes"
    else
        bad "sbs marks: two separate changes" "$marks"
    fi
    marks=$("$sbs_bin" marks "completely" "different")
    if [ "$marks" = "$(printf 'old \nnew ')" ]; then
        note "sbs marks: no shared word, nothing marked"
    else
        bad "sbs marks: unrelated lines" "$marks"
    fi
    marks=$("$sbs_bin" marks "same line" "same line")
    if [ "$marks" = "$(printf 'old \nnew ')" ]; then
        note "sbs marks: equal lines have none"
    else
        bad "sbs marks: equal lines" "$marks"
    fi

    # --- properties on random pairs
    python3 tests/oracles/sbs_random.py "$sbs_work/rand" 150 7
    got=$("$sbs_bin" propdir "$sbs_work/rand" 150 2>&1)
    case $got in
        ok*) note "sbs properties: ${got#ok } random layouts keep both files' lines, their numbers and the exact width" ;;
        *) bad "sbs properties on random pairs" "$got" ;;
    esac
    for name in $sbs_names; do
        [ "$name" = identical ] && continue
        got=$("$sbs_bin" prop "$sbs_work/fx/$name.old" "$sbs_work/fx/$name.new" 61 1000000 2>&1)
        got2=$("$sbs_bin" prop "$sbs_work/fx/$name.old" "$sbs_work/fx/$name.new" 90 3 scroll 3 2>&1)
        if [ "$got" != ok ] && [ "$got" != binary ]; then
            bad "sbs property on fixture $name" "$got"
        fi
        if [ "$got2" != ok ] && [ "$got2" != binary ]; then
            bad "sbs property on fixture $name (scrolled)" "$got2"
        fi
    done
    note "sbs properties: every named fixture checked"

    # --- git's own unified output, laid out
    tx="$sbs_work/text"
    rm -rf "$tx"
    mkdir -p "$tx"
    (
        set -e
        cd "$tx"
        export GIT_DEFAULT_HASH=sha1 GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=f@example.com GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=f@example.com
        export GIT_AUTHOR_DATE='1700000000 +0000' GIT_COMMITTER_DATE='1700000000 +0000'
        git init -q -b main .
        git config core.autocrlf false
        printf 'a\nb\nc\n' >f.txt
        printf 'x\r\ny\r\n' >crlf.txt
        printf '#!/bin/sh\necho hi\n' >s.sh
        printf '\000\001\002bin' >bin.dat
        ln -s f.txt link
        printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n' >big.txt
        git add -A
        git commit -q -m init
        printf 'a\nB\nc\nd' >f.txt
        printf 'x\ny\r\n' >crlf.txt
        chmod +x s.sh
        printf '\000\001\003bin' >bin.dat
        rm link
        ln -s big.txt link
        printf 'one\nTWO\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\nplus\n' >big.txt
        git mv s.sh t.sh
        printf 'new\tfile\twith tabs and wide \346\227\245\346\234\254\n' >new.txt
        git add -A
        git diff --cached -M >"$tx/all.diff"
        git commit -q -m 'a change

with a body'
        git show -M --format=fuller HEAD >"$tx/show.txt"
        git update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,sub
        git diff --cached >"$tx/sub.diff"
        git reset -q
        git checkout -q -b other
        printf 'left\n' >c.txt
        git add c.txt
        git commit -q -m other
        git checkout -q main
        printf 'right\n' >c.txt
        git add c.txt
        git commit -q -m main
        git merge other >/dev/null 2>&1 || true
        git diff >"$tx/conflict.diff"
    ) >"$sbs_work/text.log" 2>&1 || bad "sbs: the git fixture" "$(tail -5 "$sbs_work/text.log")"
    for f in all show sub conflict; do
        src="$tx/$f.diff"
        [ -f "$src" ] || src="$tx/$f.txt"
        "$sbs_bin" text 100 "$src" >"$sbs_work/out/text-$f" 2>&1
        sbs_golden "text-$f.100.txt" "$sbs_work/out/text-$f"
        "$sbs_bin" text 100 "$src" color >"$sbs_work/out/text-$f-c" 2>&1
        sbs_golden "text-$f.100.color.txt" "$sbs_work/out/text-$f-c"
    done
    if grep -q 'combined diff shown unified' "$sbs_work/out/text-conflict" && grep -q '^diff --cc' "$sbs_work/out/text-conflict" && grep -q '^@@@ ' "$sbs_work/out/text-conflict"; then
        note "sbs text: a combined diff keeps its unified form behind a notice"
    else
        bad "sbs text: combined diff" "$(cat "$sbs_work/out/text-conflict")"
    fi
    if grep -q 'rename from s.sh' "$sbs_work/out/text-all" && grep -q 'Binary files' "$sbs_work/out/text-all" && grep -q 'new mode 100755' "$sbs_work/out/text-all"; then
        note "sbs text: rename, mode change and binary entries are kept"
    else
        bad "sbs text: meta entries" "$(cat "$sbs_work/out/text-all")"
    fi
    if grep -q '^commit ' "$sbs_work/out/text-show" && grep -q '    with a body' "$sbs_work/out/text-show"; then
        note "sbs text: a commit's header and message pass through"
    else
        bad "sbs text: show header" "$(head -20 "$sbs_work/out/text-show")"
    fi
    # the `-` cells on the left and the `+` cells on the right are the removed
    # and added lines of git's own diff (an oracle that shares no code with it)
    for f in all show; do
        src="$tx/$f.diff"
        [ -f "$src" ] || src="$tx/$f.txt"
        got=$(python3 tests/oracles/sbs_check_text.py "$src" "$sbs_work/out/text-$f" 100 2>&1)
        if [ "$got" = ok ]; then
            note "sbs text: $f -- the left cells are git's removed lines, the right cells its added lines"
        else
            bad "sbs text: $f against git's unified lines" "$got"
        fi
    done
fi

# --- the pane drawn into a buffer says what the engine says --------------------

if [ -d "$sbs_work/fx" ] && build t_sbs_ui; then
    sbs_ui="$WORK/t_sbs_ui"
    sbs_ui_bad=0
    for name in $sbs_names; do
        for w in 61 80 120; do
            got=$("$sbs_ui" "$sbs_work/fx/$name.old" "$sbs_work/fx/$name.new" $w 40 2>&1 | tail -1)
            if [ "$got" != same ] && [ "$got" != "too narrow" ] && [ "$got" != "" ]; then
                sbs_ui_bad=$((sbs_ui_bad + 1))
                bad "sbs buffer: $name at $w columns is not the engine's rows" "$("$sbs_ui" "$sbs_work/fx/$name.old" "$sbs_work/fx/$name.new" $w 40 2>&1 | tail -3)"
            fi
        done
    done
    [ "$sbs_ui_bad" = 0 ] && note "sbs buffer: every fixture is drawn exactly as laid out"
    for depth in 16 256 true; do
        ANSI=$depth "$sbs_ui" "$sbs_work/fx/intraline.old" "$sbs_work/fx/intraline.new" 70 7 sample.c 2>&1 | grep '^\\e' >"$sbs_work/out/ansi-$depth"
        sbs_golden "buffer-ansi-$depth.txt" "$sbs_work/out/ansi-$depth"
    done
    # the old file's lexer state follows the old side and the new file's the new side:
    # `return` is a comment on the left (inside the old file's comment) and a keyword on the right
    ANSI=16 "$sbs_ui" "$sbs_work/fx/syntax_state.old" "$sbs_work/fx/syntax_state.new" 70 7 sample.c 2>&1 | grep '^\\e' >"$sbs_work/out/ansi-state"
    sbs_golden "buffer-ansi-16-syntax-state.txt" "$sbs_work/out/ansi-state"
    if [ "$(grep -o '35mreturn' "$sbs_work/out/ansi-state" | wc -l | tr -d ' ')" = 1 ]; then
        note "sbs syntax: the old side's comment state is carried (return is a keyword only on the new side)"
    else
        bad "sbs syntax: per-side lexer state" "$(cat "$sbs_work/out/ansi-state")"
    fi
fi

# --- 1git diff --side-by-side ----------------------------------------------------

if [ -d "$sbs_work/text/.git" ]; then
    if [ ! -x "$WORK/1git" ]; then
        bash scripts/build.sh git.m31 -o "$WORK/1git" >"$WORK/sbs_1git_build.log" 2>&1 || bad "sbs: scripts/build.sh git.m31" "$(tail -5 "$WORK/sbs_1git_build.log")"
    fi
    if [ -x "$WORK/1git" ]; then
        cd "$sbs_work/text" || exit 1
        # without the flag: git's own bytes, whatever the terminal says
        COLUMNS=60 "$WORK/1git" diff HEAD~1 HEAD -M >"$sbs_work/out/1git-plain" 2>&1
        git diff HEAD~1 HEAD -M >"$sbs_work/out/git-plain" 2>&1
        if cmp -s "$sbs_work/out/1git-plain" "$sbs_work/out/git-plain"; then
            note "1git diff: without --side-by-side the bytes are git's"
        else
            bad "1git diff: default output changed" "$(diff "$sbs_work/out/git-plain" "$sbs_work/out/1git-plain" | head)"
        fi
        "$WORK/1git" diff HEAD~1 HEAD -M --side-by-side --width=100 >"$sbs_work/out/1git-sbs" 2>&1
        "$sbs_bin" text 100 "$sbs_work/out/git-plain" >"$sbs_work/out/want-sbs"
        if cmp -s "$sbs_work/out/1git-sbs" "$sbs_work/out/want-sbs"; then
            note "1git diff --side-by-side is git's diff laid out in 100 columns"
        else
            bad "1git diff --side-by-side" "$(diff "$sbs_work/out/want-sbs" "$sbs_work/out/1git-sbs" | head -20)"
        fi
        "$WORK/1git" diff HEAD~1 HEAD -M -y --width=100 >"$sbs_work/out/1git-y" 2>&1
        if cmp -s "$sbs_work/out/1git-y" "$sbs_work/out/1git-sbs"; then
            note "1git diff -y is --side-by-side"
        else
            bad "1git diff -y" "$(diff "$sbs_work/out/1git-sbs" "$sbs_work/out/1git-y" | head)"
        fi
        COLUMNS=100 "$WORK/1git" diff HEAD~1 HEAD -M --side-by-side >"$sbs_work/out/1git-cols" 2>&1
        if cmp -s "$sbs_work/out/1git-cols" "$sbs_work/out/1git-sbs"; then
            note "1git diff --side-by-side takes its width from \$COLUMNS"
        else
            bad "1git diff --side-by-side: \$COLUMNS" "$(diff "$sbs_work/out/1git-sbs" "$sbs_work/out/1git-cols" | head)"
        fi
        COLUMNS=60 "$WORK/1git" diff HEAD~1 HEAD -M --side-by-side --width=100 >"$sbs_work/out/1git-w" 2>&1
        if cmp -s "$sbs_work/out/1git-w" "$sbs_work/out/1git-sbs"; then
            note "1git diff --side-by-side: --width beats \$COLUMNS"
        else
            bad "1git diff --side-by-side: --width" "$(diff "$sbs_work/out/1git-sbs" "$sbs_work/out/1git-w" | head)"
        fi
        "$WORK/1git" diff HEAD~1 HEAD -M --side-by-side --width=100 --color=always >"$sbs_work/out/1git-color" 2>&1
        git diff HEAD~1 HEAD -M --color=never >"$sbs_work/out/git-never"
        "$sbs_bin" text 100 "$sbs_work/out/git-never" color >"$sbs_work/out/want-color" 2>&1
        # the test harness shows ESC as <ESC>
        sed 's/\x1b/<ESC>/g' "$sbs_work/out/1git-color" >"$sbs_work/out/1git-color.vis" 2>/dev/null || true
        if [ "$(tr -d '\033' <"$sbs_work/out/1git-color" | wc -c)" -lt "$(wc -c <"$sbs_work/out/1git-color")" ]; then
            note "1git diff --side-by-side --color=always paints the layout"
        else
            bad "1git diff --side-by-side --color=always: no colour in the output" ""
        fi
        if ! tr -d '\033' <"$sbs_work/out/1git-sbs" | cmp -s - "$sbs_work/out/1git-sbs"; then
            bad "1git diff --side-by-side to a pipe: escapes without --color" ""
        else
            note "1git diff --side-by-side to a pipe: no escapes unless --color=always"
        fi
        "$WORK/1git" show HEAD -M --side-by-side --width=100 >"$sbs_work/out/1git-show" 2>&1
        if grep -q '^commit ' "$sbs_work/out/1git-show" && grep -q ' + ' "$sbs_work/out/1git-show"; then
            note "1git show --side-by-side keeps the commit header and lays out the diff"
        else
            bad "1git show --side-by-side" "$(head -20 "$sbs_work/out/1git-show")"
        fi
        "$WORK/1git" diff --side-by-side --width=0 >/dev/null 2>"$sbs_work/out/1git-w0"
        if [ -s "$sbs_work/out/1git-w0" ]; then
            note "1git diff --width=0 is refused"
        else
            bad "1git diff --width=0 should be refused" ""
        fi
        cd "$OLDPWD" || exit 1
    fi
fi

# --- mgit under a pty ---------------------------------------------------------------

if [ ! -x "$WORK/gitui" ]; then
    bash scripts/build.sh -o "$WORK/gitui" >"$WORK/sbs_build.log" 2>&1 \
        || bad "sbs: scripts/build.sh" "$(tail -5 "$WORK/sbs_build.log")"
fi
if [ -x "$WORK/gitui" ] && command -v python3 >/dev/null; then
    if out=$(python3 tests/pty_sbs.py "$WORK/gitui" "$WORK/ptysbs" 2>&1); then
        note "mgit side-by-side pty: $(echo "$out" | grep -c '^ok') checks"
    else
        bad "mgit side-by-side pty" "$(echo "$out" | grep -v '^ok' | head -60)"
    fi
fi
