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
#   sh install.sh --release v1.2.3   install that release instead of the newest
#   sh install.sh --prefix /usr/local   install elsewhere (needs write access)
#   sh install.sh --libc musl|gnu    force the C library flavour instead of detecting it
#   sh install.sh -uninstall         remove the links and this program's opt/ dir
#   sh install.sh --help             all of it (--r and --p are the short forms of --release and --prefix)
#   curl -fsSL <url> | sh -s -- --prefix /usr/local     options after `-s --`
#
# The grammar is Oro's (m31's docs/cli-conventions.md): -word is a command, --word
# an option. The environment still works and the options win: VERSION=v1.2.3,
# PREFIX=..., LIBC=musl|gnu. `--uninstall` (the old spelling) works for one release.
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

usage() {
    cat <<USAGE
usage: sh install.sh [options] [-uninstall]

Install the latest $REPO release for this machine (programs: $BINS).
Piped from curl, pass options after -s --:  curl -fsSL <url> | sh -s -- --prefix /usr/local

commands:
  -u, -uninstall     remove the links and this program's opt/ directory

options:
       --help        show this help
       --version     print what this installer installs and exit
  --r, --release TAG   install that release instead of the newest (env VERSION)
  --p, --prefix DIR    install under DIR instead of ~/.local (env PREFIX)
       --libc LIBC     gnu or musl: force the C library flavour instead of detecting it (env LIBC)

exit status: 0 ok, 1 the install failed, 2 usage error
USAGE
}

# usage_error MESSAGE: one line, the usage pointer, exit 2
usage_error() {
    printf 'install: %s\n' "$*" >&2
    printf "usage: sh install.sh [options] [-uninstall]\ntry 'sh install.sh --help' for more information\n" >&2
    exit 2
}

# suggest WORD KNOWN...: the known name closest to WORD (a unique prefix, else edit
# distance with neighbour swaps within 2), as " -- did you mean 'x'?", or nothing
suggest() {
    word=$1
    shift
    near=$(printf '%s\n' "$@" | awk -v w="$word" '
        function dist(a, b,    i, j, m, n, c, best, d) {
            m = length(a); n = length(b)
            for (i = 0; i <= m; i++) d[i, 0] = i
            for (j = 0; j <= n; j++) d[0, j] = j
            for (i = 1; i <= m; i++) for (j = 1; j <= n; j++) {
                c = (substr(a, i, 1) == substr(b, j, 1)) ? 0 : 1
                best = d[i - 1, j] + 1
                if (d[i, j - 1] + 1 < best) best = d[i, j - 1] + 1
                if (d[i - 1, j - 1] + c < best) best = d[i - 1, j - 1] + c
                if (i > 1 && j > 1 && substr(a, i, 1) == substr(b, j - 1, 1) && substr(a, i - 1, 1) == substr(b, j, 1) && d[i - 2, j - 2] + 1 < best) best = d[i - 2, j - 2] + 1
                d[i, j] = best
            }
            return d[m, n]
        }
        { k = dist(w, $0); if (k <= 2 && (best == "" || k < bestk)) { best = $0; bestk = k } }
        END { print best }')
    if [ -n "$near" ]; then
        printf " -- did you mean '%s'?" "$near"
    fi
}

# take_value NAME VALUE: a value is never something that starts with a dash
take_value() {
    [ -n "${2+x}" ] || usage_error "'$1' needs a value and is the last argument"
    case $2 in
        -?*) usage_error "'$1' needs a value, and '$2' starts with a dash -- write '$1=$2' if that is the value you meant" ;;
    esac
}

is_uninstall=0
while [ $# -gt 0 ]; do
    case $1 in
        --help) usage; exit 0 ;;
        --version) say "$REPO installer: installs the newest release, or --release TAG"; exit 0 ;;
        -u|-uninstall) is_uninstall=1 ;;
        --uninstall)
            printf "install: warning: '--uninstall' is deprecated, use '-uninstall'\n" >&2
            is_uninstall=1
            ;;
        --release|--r|--prefix|--p|--libc)
            take_value "$1" "${2-}"
            [ $# -ge 2 ] || usage_error "'$1' needs a value and is the last argument"
            case $1 in
                --release|--r) VERSION=$2 ;;
                --prefix|--p) PREFIX=$2 ;;
                --libc) LIBC=$2 ;;
            esac
            shift
            ;;
        --release=*) VERSION=${1#--release=} ;;
        --r=*) VERSION=${1#--r=} ;;
        --prefix=*) PREFIX=${1#--prefix=} ;;
        --p=*) PREFIX=${1#--p=} ;;
        --libc=*) LIBC=${1#--libc=} ;;
        -h|-help) usage_error "'$1' would be a command here, and there is none called '${1#-}' -- help is an option, so write '--help'" ;;
        help) usage_error "'help' is an option here, not a command -- write '--help'" ;;
        --h) usage_error "'--h' is not an option -- help has one spelling, and it is '--help'" ;;
        --) usage_error "'--' has no meaning here -- data is data because it does not start with a dash, so nothing has to be marked off" ;;
        --pr|--rp) usage_error "'$1': short options do not cluster -- write '--p --r'" ;;
        --*) usage_error "unknown option '${1%%=*}'$(suggest "${1%%=*}" --help --version --release --prefix --libc)" ;;
        -[0-9]*) usage_error "unexpected argument '$1'" ;;
        -*) usage_error "unknown command '$1'$(suggest "$1" -uninstall)" ;;
        *) usage_error "unexpected argument '$1'" ;;
    esac
    shift
done
case ${LIBC:-} in
    ""|gnu|musl) ;;
    *) usage_error "'--libc' needs gnu or musl, and got '$LIBC'" ;;
esac
OPT="$PREFIX/opt/$REPO"
BIN="$PREFIX/bin"

if [ "$is_uninstall" = 1 ]; then
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
