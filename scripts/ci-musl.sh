#!/bin/sh
# Alpine / musl release build: run INSIDE an alpine container with the repo
# mounted as the working directory (see .github/workflows/release.yml):
#
#   docker run --rm -e M31_MUSL_REF -e GITHUB_SHA -e GITHUB_REF_NAME \
#     -v "$PWD:/w" -w /w alpine:3.22 sh scripts/ci-musl.sh
#
# Downloads the m31 musl release (static compiler + runtime SDK), builds the
# programs with it and Alpine's own cc, smoke-runs them, and writes
# gitui-linux-<arch>-musl.tar.gz with the same layout as the glibc tarballs.
# It runs as a plain `docker run`, not a job container: the JS actions
# (checkout, upload-artifact) need glibc node on the host.
set -eu
cd "$(dirname "$0")/.."

: "${M31_MUSL_REF:?M31_MUSL_REF is not set}"
# bash + GNU tools: scripts/build.sh is bash; git: m31c fetches `deps` with it.
apk add --no-cache bash curl tar gzip git coreutils sed grep gawk gcc musl-dev linux-headers >/dev/null
git config --global --add safe.directory "*"

arch=$(uname -m)
case "$arch" in arm64) arch=aarch64 ;; esac

M31_DIR=${M31_DIR:-/opt/m31}
mkdir -p "$M31_DIR"
curl -fsSL "https://github.com/qrazil/m31/releases/download/$M31_MUSL_REF/m31-linux-$arch-musl.tar.gz" |
    tar -C "$M31_DIR" -xzf -
chmod +x "$M31_DIR/m31c"
export LANGC="$M31_DIR/m31c" M31_ROOT="$M31_DIR"

OUT="dist/gitui-linux-$arch-musl"
rm -rf dist
mkdir -p "$OUT"
bash scripts/build.sh git.m31 -o "$OUT/1git"
bash scripts/build.sh gitui.m31 -o "$OUT/mgit"
cp README.md docs/design.md docs/FRICTION.md "$OUT/" 2>/dev/null || true
cat >"$OUT/NOTES.txt" <<EOF
gitui - Linux $arch (musl / Alpine) release build
Built from commit: ${GITHUB_SHA:-unknown}
Tag: ${GITHUB_REF_NAME:-unknown}
Built against m31 $M31_MUSL_REF, tui $(awk '$1=="tui"{print $3}' deps)

1git                          ./1git -log --max 5
mgit                          ./mgit (run from a repository's own top level)
EOF

# Smoke: run what was just built, in this container.
"$OUT/1git" --help >/dev/null
"$OUT/1git" -log --max 1 >/dev/null
[ -x "$OUT/mgit" ]

tar -C "$OUT" -czf "gitui-linux-$arch-musl.tar.gz" .
ls -l "gitui-linux-$arch-musl.tar.gz"
