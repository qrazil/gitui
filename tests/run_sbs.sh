#!/usr/bin/env bash
# Only the side-by-side checks (`test_sbs.sh`), without the rest of `test.sh`:
#
#   M31_ROOT=/path/to/m31 LANGC=/path/to/m31c bash tests/run_sbs.sh
#   UPDATE_GOLDEN=1 ... bash tests/run_sbs.sh      # rewrite tests/golden/sbs/
#
# The mgit and 1git checks use `$WORK/gitui` and `$WORK/1git`; point
# `SBS_MGIT` / `SBS_1GIT` at binaries you already built to skip building them.
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
    local name=$1
    local src="tests/$name.m31"
    [ -f "$src" ] || src="$name.m31"
    if ! "$LANGC" --emit-c "$src" -o "$WORK/$name.c" 2>"$WORK/$name.diag"; then
        bad "compile $name" "$(grep -v '^warning' "$WORK/$name.diag" | head -5)"
        return 1
    fi
    if ! cc -O2 -w -I "$M31_ROOT/runtime" -pthread -o "$WORK/$name" "$WORK/$name.c" \
           "$M31_ROOT/runtime/rt.c" "$M31_ROOT/runtime/scheduler.c" "$M31_ROOT/$RT_REACTOR_C" "$M31_ROOT/$RT_CTX_ASM" \
           2>"$WORK/$name.cc"; then
        bad "cc $name" "$(head -5 "$WORK/$name.cc")"
        return 1
    fi
    return 0
}
[ -n "${SBS_MGIT:-}" ] && cp "$SBS_MGIT" "$WORK/gitui"
[ -n "${SBS_1GIT:-}" ] && cp "$SBS_1GIT" "$WORK/1git"
source tests/test_sbs.sh
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
