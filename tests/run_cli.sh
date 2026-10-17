#!/usr/bin/env bash
# Only the command-line checks (`test_cli.sh`), without the rest of `test.sh`:
#
#   M31_ROOT=/path/to/m31 LANGC=/path/to/m31c bash tests/run_cli.sh
#   UPDATE_GOLDEN=1 ... bash tests/run_cli.sh     # rewrite tests/golden/cli/ and docs/CLI-REFERENCE.md
#
# CLI_1GIT, CLI_T_CLI and CLI_MGIT name binaries already built (1git, the t_cli
# unit, mgit) to skip building them.
set -uo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1
unset VISUAL GIT_EDITOR EDITOR GIT_SEQUENCE_EDITOR
export LC_ALL=C TZ=UTC
if [ -z "${M31_ROOT:-}" ] || [ ! -f "$M31_ROOT/config.sh" ]; then
    echo "M31_ROOT is not set to an m31 release or checkout" >&2
    exit 1
fi
. "$M31_ROOT/runtime/arch.sh"
LANGC=${LANGC:-./m31c}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0
note() { printf '\033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '\033[31mFAIL\033[0m %s\n' "$1"; shift; printf '%s\n' "$@" | sed 's/^/     /'; fail=$((fail + 1)); }
build() {
    local name=$1 src="tests/$1.m31"
    [ -f "$src" ] || src="$name.m31"
    case $name in
        git) [ -n "${CLI_1GIT:-}" ] && { cp "$CLI_1GIT" "$WORK/git"; return 0; } ;;
        t_cli) [ -n "${CLI_T_CLI:-}" ] && { cp "$CLI_T_CLI" "$WORK/t_cli"; return 0; } ;;
    esac
    if ! "$LANGC" -emit-c "$src" --out "$WORK/$name.c" 2>"$WORK/$name.diag"; then
        bad "compile $name" "$(grep -v '^m31c: warning' "$WORK/$name.diag" | head -5)"
        return 1
    fi
    if ! cc -O2 -I "$M31_ROOT/runtime" -pthread -o "$WORK/$name" "$WORK/$name.c" \
           "$M31_ROOT/runtime/rt.c" "$M31_ROOT/runtime/scheduler.c" "$M31_ROOT/$RT_REACTOR_C" "$M31_ROOT/$RT_CTX_ASM" \
           2>"$WORK/$name.cc"; then
        bad "cc $name" "$(head -5 "$WORK/$name.cc")"
        return 1
    fi
}
[ -n "${CLI_MGIT:-}" ] && cp "$CLI_MGIT" "$WORK/mgit"
source tests/test_cli.sh
echo
if [ $fail -eq 0 ]; then
    printf '\033[32mall %d checks passed\033[0m\n' "$pass"
else
    printf '\033[31m%d of %d checks FAILED\033[0m\n' "$fail" "$((pass + fail))"
fi
exit $fail
