#!/usr/bin/env bash
#
# 07p-install-prebuilt.sh — Install prebuilt DXMT fork + patched winemac.so
# instead of building them (replaces 07-build-dxmt-fork.sh and
# 08-patch-wine-visibility.sh when install.sh is run with --prebuilt).
#
# Skips the ~1.5 hour LLVM 15 / DXMT / Wine source builds. The bundle is
# produced by scripts/package-prebuilt.sh; its BUILD-INFO.md lists the exact
# source commits and patches used.
#
# Env overrides:
#   PREBUILT_URL      bundle URL
#   PREBUILT_SHA256   expected SHA256 of the bundle ("" disables the check)

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_macos_arm64
require_wine_installed

PREBUILT_VERSION="macos26-1"
PREBUILT_NAME="steam-on-m1-wine-prebuilt-${PREBUILT_VERSION}"
PREBUILT_URL="${PREBUILT_URL:-https://github.com/alexwinskii/steam-on-m1-wine/releases/download/prebuilt-${PREBUILT_VERSION}/${PREBUILT_NAME}.tar.gz}"
PREBUILT_SHA256="${PREBUILT_SHA256-693c2688e3f4c9768754f67d9ecc35e69bdb7066ecb55300975653544d1d4ff0}"

# The bundled winemac.so is built from wine-11.0 and must match the
# installed Wine exactly.
EXPECTED_WINE_VERSION="wine-11.0"

WINE_LIB_UNIX="$WINE_APP/Contents/Resources/wine/lib/wine/x86_64-unix"
WINE_LIB_WIN64="$WINE_APP/Contents/Resources/wine/lib/wine/x86_64-windows"
WINE_LIB_WIN32="$WINE_APP/Contents/Resources/wine/lib/wine/i386-windows"
PREFIX_SYS32="$WINEPREFIX/drive_c/windows/system32"
PREFIX_SYSWOW64="$WINEPREFIX/drive_c/windows/syswow64"

CACHE_DIR="${PREBUILT_CACHE:-$HOME/Library/Caches/steam-on-m1-wine}"
TARBALL="$CACHE_DIR/${PREBUILT_NAME}.tar.gz"

log_step "Installing prebuilt DXMT + winemac.so (${PREBUILT_VERSION})"

# -- Wine version guard -------------------------------------------------------
wine_version=$(run_x86_64 "$WINE_BIN" --version 2>&1 || true)
if [[ "$wine_version" != "$EXPECTED_WINE_VERSION" ]]; then
    die "Prebuilt bundle targets $EXPECTED_WINE_VERSION but installed Wine is '$wine_version'." \
        "Run install.sh without --prebuilt to build from source."
fi
log_ok "Wine version matches: $wine_version"

# -- Download + verify --------------------------------------------------------
mkdir -p "$CACHE_DIR"
if [[ ! -f "$TARBALL" ]]; then
    log_info "Downloading $PREBUILT_URL"
    curl -fL --retry 3 --retry-delay 2 -o "$TARBALL.part" "$PREBUILT_URL" \
        || die "Download failed: $PREBUILT_URL"
    mv "$TARBALL.part" "$TARBALL"
else
    log_ok "Bundle already cached at $TARBALL"
fi

if [[ -n "$PREBUILT_SHA256" ]]; then
    actual=$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)
    if [[ "$actual" != "$PREBUILT_SHA256" ]]; then
        rm -f "$TARBALL"
        die "Checksum mismatch (expected $PREBUILT_SHA256, got $actual). Deleted the download; re-run to retry."
    fi
    log_ok "SHA256 verified"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
tar -xzf "$TARBALL" -C "$WORK" || die "Failed to extract $TARBALL"
BUNDLE="$WORK/$PREBUILT_NAME"
[[ -d "$BUNDLE" ]] || die "Unexpected bundle layout (no $PREBUILT_NAME/ directory)"

( cd "$BUNDLE" && shasum -a 256 -c SHA256SUMS --quiet ) \
    || die "Per-file checksums in SHA256SUMS did not match"
log_ok "Per-file checksums verified"
xattr -cr "$BUNDLE" 2>/dev/null || true

# -- Install ------------------------------------------------------------------
# Files inside /Applications may be root-owned if Wine came from the cask.
install_file() {
    local src=$1 dst=$2
    [[ -f "$src" ]] || die "Missing file in bundle: $src"
    if ! cp "$src" "$dst" 2>/dev/null; then
        log_info "Need admin rights to write $dst"
        sudo cp "$src" "$dst" || die "Failed to install $dst"
    fi
    log_ok "$(basename "$src") -> $dst"
}

backup="$WINE_LIB_UNIX/winemac.so.gcenx-backup"
if [[ ! -f "$backup" ]]; then
    log_info "Backing up original winemac.so to $backup"
    cp "$WINE_LIB_UNIX/winemac.so" "$backup" 2>/dev/null \
        || sudo cp "$WINE_LIB_UNIX/winemac.so" "$backup" \
        || die "Failed to back up winemac.so"
fi

install_file "$BUNDLE/x86_64-unix/winemac.so"   "$WINE_LIB_UNIX/winemac.so"
install_file "$BUNDLE/x86_64-unix/winemetal.so" "$WINE_LIB_UNIX/winemetal.so"
for dll in d3d11.dll d3d10core.dll dxgi.dll winemetal.dll; do
    install_file "$BUNDLE/x86_64-windows/$dll" "$WINE_LIB_WIN64/$dll"
    install_file "$BUNDLE/i386-windows/$dll"   "$WINE_LIB_WIN32/$dll"
done
cp "$BUNDLE/x86_64-windows/winemetal.dll" "$PREFIX_SYS32/winemetal.dll" 2>/dev/null || true
cp "$BUNDLE/i386-windows/winemetal.dll"   "$PREFIX_SYSWOW64/winemetal.dll" 2>/dev/null || true

# -- Verify -------------------------------------------------------------------
pub=$(nm -g "$WINE_LIB_UNIX/winemac.so" 2>/dev/null | grep -c ' T ' || true)
(( pub >= 100 )) || die "Installed winemac.so has only $pub public symbols; install did not take."
log_ok "winemac.so exports $pub public symbols"
log_ok "Prebuilt DXMT stack installed (skipped source builds)"
