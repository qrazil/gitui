#!/usr/bin/env bash
# Build gitui (`gitui.m31`, the interactive client) or the read-only CLI
# (`git.m31`) into a real executable, like the other qrazil apps' one
# scripts/build.sh.
#
#   M31_ROOT=/path/to/m31 bash scripts/build.sh                  -> ./mgit
#   M31_ROOT=/path/to/m31 bash scripts/build.sh -o name          -> ./name
#   M31_ROOT=/path/to/m31 bash scripts/build.sh git.m31          -> ./1git
#   M31_ROOT=/path/to/m31 bash scripts/build.sh tests/t_x.m31 -o t_x
#
# Any other `.m31` file builds into ./<its basename>. `gitui.m31` imports
# github.com/qrazil/tui as `import tui.app.TUI_app;` and so on: the `deps`
# file at the repo root names the exact commit, and the first compile fetches
# it into `.m31-deps/` and records it in `deps.lock`.
#
# Needs LANGC (the m31c compiler binary, v0.4.0 or later; default ./m31c) and
# M31_ROOT (a checkout of github.com/qrazil/m31, or an extracted release's
# runtime SDK containing config.sh and runtime/). There is no pre-built
# runtime library to link against.
set -uo pipefail
cd "$(dirname "$0")/.."

if [ -z "${M31_ROOT:-}" ]; then
    echo "M31_ROOT is not set -- point it at a checkout of github.com/qrazil/m31" \
         "(or an extracted release's runtime SDK) matching the m31c version" \
         "you're building with. See this script's own header comment." >&2
    exit 1
fi
if [ ! -f "$M31_ROOT/config.sh" ] || [ ! -d "$M31_ROOT/runtime" ]; then
    echo "M31_ROOT=$M31_ROOT does not look like an m31 checkout" \
         "(expected $M31_ROOT/config.sh and $M31_ROOT/runtime/)" >&2
    exit 1
fi

. "$M31_ROOT/config.sh"
. "$M31_ROOT/runtime/arch.sh"

LANGC=${LANGC:-./m31c}
CC=${CC:-cc}

src=gitui.m31
out=
while [ $# -gt 0 ]; do
    case $1 in
        -o) out=${2:?-o needs a name}; shift 2 ;;
        -*) echo "usage: M31_ROOT=/path/to/m31 bash scripts/build.sh [source.m31] [-o out]" >&2; exit 1 ;;
        *)  src=$1; shift ;;
    esac
done
if [ -z "$out" ]; then
    case $src in
        gitui.m31) out=mgit ;;
        git.m31)   out=1git ;;
        *)         out=$(basename "$src" ".$LANG_EXT") ;;
    esac
fi

if [ ! -x "$LANGC" ]; then
    echo "compiler not found or not executable: $LANGC" >&2
    exit 1
fi

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

"$LANGC" --emit-c "$src" -o "$tmp/out.c" || exit 1
# RT_REACTOR_C/RT_CTX_ASM (from runtime/arch.sh above) are paths relative to
# M31_ROOT, not to this script's own directory -- prefix them before use.
"$CC" -O2 -pthread -I "$M31_ROOT/runtime" -o "$out" "$tmp/out.c" \
    "$M31_ROOT/runtime/rt.c" "$M31_ROOT/runtime/scheduler.c" \
    "$M31_ROOT/$RT_REACTOR_C" "$M31_ROOT/$RT_CTX_ASM"
echo "$out"
