#!/bin/sh
# Install the latest m31git release (mgit and 1git) for this machine, no tarball juggling:
#
#   curl -fsSL https://raw.githubusercontent.com/qrazil/m31git/master/install.sh | sh
#
# Picks the asset for this OS and CPU (Linux x86-64 / aarch64, macOS arm64;
# on a musl system -- Alpine -- the -musl Linux asset, falling back to the
# glibc one for a release that predates it; releases up to v0.22.0 name their
# assets gitui-*, those are found too; the download is checked against the
# release's SHA256SUMS when there is one),
# unpacks it under $PREFIX/opt/m31git/<version> and links the programs into
# $PREFIX/bin. PREFIX defaults to ~/.local. Re-running upgrades; old versions
# stay in opt/ until you delete them.
#
#   VERSION=v1.2.3   install that release instead of the newest
#   PREFIX=/usr/local  install elsewhere (needs write access)
#   LIBC=musl|gnu    force the C library flavour instead of detecting it
#   sh install.sh --uninstall   remove the links and this program's opt/ dir
set -eu

REPO=m31git
ASSET=m31git         # release asset prefix: <ASSET>-<os>-<arch>.tar.gz
OLD_ASSET=gitui      # the prefix of releases up to v0.22.0
BINS="mgit 1git"          # programs linked into $PREFIX/bin
PREFIX=${PREFIX:-$HOME/.local}
OPT="$PREFIX/opt/$REPO"
BIN="$PREFIX/bin"

say() { printf '%s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

if [ "${1:-}" = "--uninstall" ]; then
    for b in $BINS; do
        [ -L "$BIN/$b" ] && rm -f "$BIN/$b" && say "removed $BIN/$b"
    done
    rm -rf "$OPT" && say "removed $OPT"
    exit 0
fi

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar  >/dev/null 2>&1 || die "tar is required"

case "$(uname -s)" in
    Linux)  os=linux ;;
    Darwin) os=macos ;;
    *) die "unsupported OS: $(uname -s) (releases exist for Linux and macOS)" ;;
esac
case "$(uname -m)" in
    x86_64|amd64)  arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) die "unsupported CPU: $(uname -m)" ;;
esac
[ "$os" = macos ] && arch=arm64
[ "$os" = macos ] && [ "$(uname -m)" != arm64 ] && die "macOS releases are Apple silicon (arm64) only"

if [ -z "${VERSION:-}" ]; then
    # The newest release, prereleases included (the /latest alias skips them).
    VERSION=$(curl -fsSL "https://api.github.com/repos/qrazil/$REPO/releases?per_page=1" |
        sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
    [ -n "$VERSION" ] || die "could not find a release of $REPO"
fi

# C library flavour on Linux: musl (Alpine) gets its own asset. Detected from
# /etc/alpine-release or ldd's banner (musl's ldd prints "musl libc" on stderr,
# exit status 1).
libc=${LIBC:-}
if [ -z "$libc" ] && [ "$os" = linux ]; then
    libc=gnu
    if [ -e /etc/alpine-release ] ||
        { ldd --version 2>&1 || true; } | grep -qi musl; then
        libc=musl
    fi
fi
base="https://github.com/qrazil/$REPO/releases/download/$VERSION"
# Asset names: m31git-<os>-<arch>[-musl].tar.gz since 0.21.0; releases up to
# v0.22.0 name them gitui-<os>-<arch>[-musl].tar.gz. Tried in this order, the
# first one that exists wins: for musl the musl assets (new, then old), then
# the glibc ones (a release that predates the musl assets; the glibc build
# will not run on musl without gcompat, but say so and carry on).
cands=""
if [ "$libc" = musl ] && [ "$os" = linux ]; then
    cands="$ASSET-$os-$arch-musl.tar.gz $OLD_ASSET-$os-$arch-musl.tar.gz"
fi
cands="$cands $ASSET-$os-$arch.tar.gz $OLD_ASSET-$os-$arch.tar.gz"
file=
for c in $cands; do
    if curl -fsSLI "$base/$c" >/dev/null 2>&1; then
        file=$c
        break
    fi
done
[ -n "$file" ] || die "no release asset for $os $arch in $VERSION ($base)"
if [ "$libc" = musl ] && [ "$os" = linux ]; then
    case "$file" in *-musl.tar.gz) ;; *) say "no musl asset in $VERSION; using the glibc one" ;; esac
fi
url="$base/$file"
dest="$OPT/$VERSION"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/$REPO-install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

say "$REPO $VERSION ($os $arch${libc:+ $libc})"
curl -fsSL "$url" -o "$tmp/$file" || die "download failed: $url"

# Verify against the release's SHA256SUMS when it has one (releases from 0.21.0
# on); older releases have none, which is fine.
if curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS" 2>/dev/null; then
    want=$(awk -v f="$file" '{n=$2; sub(/^\*/, "", n); if (n == f) print $1}' "$tmp/SHA256SUMS" | head -n 1)
    if [ -z "$want" ]; then
        say "SHA256SUMS has no entry for $file; not verified"
    else
        if command -v sha256sum >/dev/null 2>&1; then
            got=$(sha256sum "$tmp/$file" | awk '{print $1}')
        elif command -v shasum >/dev/null 2>&1; then
            got=$(shasum -a 256 "$tmp/$file" | awk '{print $1}')
        else
            got=
            say "no sha256sum or shasum here; $file not verified"
        fi
        if [ -n "$got" ]; then
            [ "$got" = "$want" ] || die "checksum mismatch for $file (wanted $want, got $got)"
            say "checksum ok"
        fi
    fi
else
    say "no SHA256SUMS in $VERSION; not verified"
fi
mkdir -p "$tmp/x" "$BIN" "$OPT"
tar -xzf "$tmp/$file" -C "$tmp/x" || die "could not unpack $file"

rm -rf "$dest"
mv "$tmp/x" "$dest"
# 0.9.0 linked the programs as ourgitui and ourgit.
for old in ourgitui ourgit; do
    [ -L "$BIN/$old" ] && case "$(readlink "$BIN/$old")" in "$OPT"/*) rm -f "$BIN/$old" ;; esac
done
for b in $BINS; do
    [ -x "$dest/$b" ] || die "$b is not in the release ($dest)"
    ln -sf "$dest/$b" "$BIN/$b"
    say "linked $BIN/$b"
done

case ":$PATH:" in
    *":$BIN:"*) ;;
    *) say "add $BIN to your PATH:  export PATH=\"$BIN:\$PATH\"" ;;
esac
