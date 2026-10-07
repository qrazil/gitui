#!/usr/bin/env bash
# Build git.m31 (the read-only CLI) into a real executable. Not for
# gitui.m31 -- see scripts/build-gitui.sh's own header for why that one needs a
# dependency on tui (git.m31 has none) and so builds from the project root.
#
#   M31_ROOT=/path/to/m31 bash scripts/build.sh git.m31           -> ./git
#   M31_ROOT=/path/to/m31 bash scripts/build.sh git.m31 -o ourgit
#
# git.m31 is one `.m31` file, compiled by the m31 compiler (m31c) and then
# linked, as ordinary C, against the m31 RUNTIME's own source files -- there
# is no pre-built runtime library to link against instead, so this script
# needs both:
#
#   - LANGC: the m31c compiler binary (env var, default ./m31c beside this
#     script -- where a downloaded release binary lands).
#   - M31_ROOT: a directory containing the m31 project's own config.sh and
#     runtime/ (a checkout of github.com/qrazil/m31, or an extracted
#     release's bundled runtime SDK -- see that repo's own release.yml)
#     matching the version LANGC was built from. No default: a missing
#     M31_ROOT is a clear error instead of a guess.
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

src=${1:?usage: M31_ROOT=/path/to/m31 bash scripts/build.sh <source.m31> [-o out]}
out=$(basename "$src" ".$LANG_EXT")
[ "${2:-}" = "-o" ] && out=${3:?-o needs a name}

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
