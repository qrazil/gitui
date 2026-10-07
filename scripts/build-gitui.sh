#!/usr/bin/env bash
# Build the interactive client (`gitui.m31`) into a real executable.
#
#   M31_ROOT=/path/to/m31 bash scripts/build-gitui.sh
#       -> ./ourgitui
#   M31_ROOT=/path/to/m31 bash scripts/build-gitui.sh -o mygitui
#       -> ./mygitui
#
# `gitui.m31` imports this repo's own plumbing and github.com/qrazil/tui's
# widgets as `import tui.tuiapp;` and so on. The `deps` file at the repo root
# names tui and the exact commit; the first compile fetches it into
# `.m31-deps/` and records it in `deps.lock`, so nothing is staged or copied.
#
# Also needs LANGC (the m31c compiler binary, v0.2.0 or later) and M31_ROOT (a
# checkout of github.com/qrazil/m31, or an extracted release's bundled runtime
# SDK, containing config.sh and runtime/) -- there is no pre-built runtime
# library to link against instead.
set -euo pipefail
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

out=ourgitui
[ "${1:-}" = "-o" ] && out=${2:?-o needs a name}

LANGC=${LANGC:-./m31c}
CC=${CC:-cc}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ ! -x "$LANGC" ]; then
    echo "compiler not found or not executable: $LANGC" >&2
    exit 1
fi

"$LANGC" --emit-c gitui.m31 -o "$tmp/gitui.c"
# RT_REACTOR_C/RT_CTX_ASM (from runtime/arch.sh above) are paths relative to
# M31_ROOT, not to this script's own directory -- prefix them before use.
"$CC" -O2 -pthread -I "$M31_ROOT/runtime" -o "$out" "$tmp/gitui.c" \
    "$M31_ROOT/runtime/rt.c" "$M31_ROOT/runtime/scheduler.c" \
    "$M31_ROOT/$RT_REACTOR_C" "$M31_ROOT/$RT_CTX_ASM"
echo "$out"
