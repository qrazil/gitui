#!/usr/bin/env bash
# Build the interactive client (`gitui.m31`) into a real executable.
#
#   M31_ROOT=/path/to/m31 TUI_ROOT=/path/to/tui bash build-gitui.sh
#       -> ./ourgitui
#   M31_ROOT=/path/to/m31 TUI_ROOT=/path/to/tui bash build-gitui.sh -o mygitui
#       -> ./mygitui
#
# `gitui.m31`'s entry point lives at this repo's root, and imports both this
# repo's own plumbing (`gitclient`, `gitlog`, `status`, `gitignore`, `index`,
# `object`, `pack`, `refs`, `repo`, `sha1`, `zlib`, `hunks`, `patch`) and several
# github.com/qrazil/tui widgets (`tuiapp`, `tuioutline`, `tuijump`,
# `tuimenu`, `tuifooter`, `tuidiffview`, and what those pull in). The
# compiler resolves every `import` against the ENTRY file's own directory
# only (docs/modules-decision.md section 1 in qrazil/m31: one flat
# namespace, no search path) -- so a program built straight out of this
# repo can never see qrazil/tui's files sitting in a different checkout.
#
# The fix, the same one this repo used when it was apps/git inside the m31
# monorepo (next to apps/tui): copy every file this program's own module
# graph needs -- both halves -- into a throwaway staging directory, compile
# the entry from there, and throw the staging directory away. TUI_ROOT is
# that other half now: a checkout of github.com/qrazil/tui (pinned to
# whatever commit this repo's own CI/docs name), not a sibling directory in
# this repo.
#
# Also needs LANGC (the m31c compiler binary) and M31_ROOT (a checkout of
# github.com/qrazil/m31, or an extracted release's bundled runtime SDK,
# containing config.sh and runtime/) -- there is no pre-built runtime
# library to link against instead.
set -euo pipefail
cd "$(dirname "$0")"

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
if [ -z "${TUI_ROOT:-}" ]; then
    echo "TUI_ROOT is not set -- point it at a checkout of github.com/qrazil/tui" \
         "matching the commit this repo's own CI pins. See this script's own" \
         "header comment." >&2
    exit 1
fi
if [ ! -f "$TUI_ROOT/tuiapp.m31" ]; then
    echo "TUI_ROOT=$TUI_ROOT does not look like a qrazil/tui checkout" \
         "(expected $TUI_ROOT/tuiapp.m31)" >&2
    exit 1
fi

. "$M31_ROOT/config.sh"
. "$M31_ROOT/runtime/arch.sh"

out=ourgitui
[ "${1:-}" = "-o" ] && out=${2:?-o needs a name}

LANGC=${LANGC:-./m31c}
CC=${CC:-cc}
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

if [ ! -x "$LANGC" ]; then
    echo "compiler not found or not executable: $LANGC" >&2
    exit 1
fi

cp "$TUI_ROOT/tuiapp.m31" "$TUI_ROOT/tuibuf.m31" "$TUI_ROOT/tuidiff.m31" \
    "$TUI_ROOT/tuidiffview.m31" "$TUI_ROOT/tuifooter.m31" "$TUI_ROOT/tuigeom.m31" \
    "$TUI_ROOT/tuijump.m31" "$TUI_ROOT/tuimenu.m31" "$TUI_ROOT/tuioutline.m31" \
    "$TUI_ROOT/tuiscroll.m31" "$TUI_ROOT/tuistyle.m31" "$TUI_ROOT/tuitext.m31" \
    "$TUI_ROOT/tuiwidget.m31" \
    repo.m31 sha1.m31 zlib.m31 pack.m31 object.m31 \
    refs.m31 index.m31 gitignore.m31 status.m31 checkout.m31 \
    gitlog.m31 hunks.m31 patch.m31 gitclient.m31 gitui.m31 \
    "$stage/"

"$LANGC" --emit-c "$stage/gitui.m31" -o "$stage/gitui.c"
# RT_REACTOR_C/RT_CTX_ASM (from runtime/arch.sh above) are paths relative to
# M31_ROOT, not to this script's own directory -- prefix them before use.
"$CC" -O2 -pthread -I "$M31_ROOT/runtime" -o "$out" "$stage/gitui.c" \
    "$M31_ROOT/runtime/rt.c" "$M31_ROOT/runtime/scheduler.c" \
    "$M31_ROOT/$RT_REACTOR_C" "$M31_ROOT/$RT_CTX_ASM"
echo "$out"
