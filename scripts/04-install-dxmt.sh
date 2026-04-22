#!/usr/bin/env bash
#
# 04-install-dxmt.sh — Install DXMT DLLs into the Wine runtime and the
# WINEPREFIX, so Direct3D 11 calls from Chromium's ANGLE are translated
# to Metal instead of going through wined3d's OpenGL path.
#
# Without this step, Steam's CEF-based UI renders a completely black
# window because wined3d on Apple Silicon cannot satisfy Chrome's
# GLES 3.0 requirement.
#
# References:
#   https://github.com/3Shain/dxmt/wiki/DXMT-Installation-Guide-for-Geeks
#   https://github.com/3Shain/dxmt/issues/141
#
# Idempotent: re-running replaces previously placed DLLs with the
# pinned release's copies.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_wine_installed
require_prefix_initialised

# Pinned release. Bump deliberately; keep this file and README in sync.
DXMT_TAG="v0.74"
DXMT_ASSET="dxmt-${DXMT_TAG}-builtin.tar.gz"
DXMT_URL="https://github.com/3Shain/dxmt/releases/download/${DXMT_TAG}/${DXMT_ASSET}"
# SHA256 of the asset. Obtain from:
#   curl -sSL ${DXMT_URL} | shasum -a 256
# Pinning this matters: DXMT v0.74 is under active development and a
# re-tagged asset would ship silently. To bump, edit DXMT_TAG above,
# re-download, recompute this hash, and test end-to-end before committing.
DXMT_SHA256="${DXMT_SHA256_OVERRIDE:-2598981a8b725653773e277470a95dda4253b8a14d36e0dc96dce0e3800f0ceb}"

VENDOR_DIR="$REPO_ROOT/vendor/dxmt-${DXMT_TAG}"
TARBALL="$VENDOR_DIR/${DXMT_ASSET}"

WINE_LIB_UNIX="$WINE_APP/Contents/Resources/wine/lib/wine/x86_64-unix"
WINE_LIB_WIN64="$WINE_APP/Contents/Resources/wine/lib/wine/x86_64-windows"
WINE_LIB_WIN32="$WINE_APP/Contents/Resources/wine/lib/wine/i386-windows"
PREFIX_SYS32="$WINEPREFIX/drive_c/windows/system32"
PREFIX_SYSWOW64="$WINEPREFIX/drive_c/windows/syswow64"

log_step "Installing DXMT ${DXMT_TAG}"

mkdir -p "$VENDOR_DIR"

# -- Download -----------------------------------------------------------------
if [[ ! -f "$TARBALL" ]]; then
    log_info "Downloading $DXMT_URL"
    curl -fL --retry 3 --retry-delay 2 -o "$TARBALL" "$DXMT_URL" \
        || die "Failed to download DXMT"
else
    log_ok "Tarball already present: $TARBALL"
fi

# -- Verify checksum (optional but recommended) -------------------------------
if [[ -n "$DXMT_SHA256" ]]; then
    actual=$(shasum -a 256 "$TARBALL" | awk '{print $1}')
    if [[ "$actual" != "$DXMT_SHA256" ]]; then
        die "Checksum mismatch for $TARBALL (expected $DXMT_SHA256, got $actual)"
    fi
    log_ok "SHA256 verified"
else
    log_warn "DXMT_SHA256 not pinned in this script — skipping checksum check."
    log_warn "Compute and pin: shasum -a 256 '$TARBALL'"
fi

# -- Extract ------------------------------------------------------------------
EXTRACT_DIR="$VENDOR_DIR/extracted"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$TARBALL" -C "$EXTRACT_DIR"

# The tarball's top-level directory layout (v0.74):
#   x86_64-unix/winemetal.so
#   x86_64-windows/{d3d11,d3d10core,dxgi,nvapi64,nvngx,winemetal}.dll
#   i386-windows/{d3d11,d3d10core,dxgi,winemetal}.dll
# Find the extracted root regardless of how tar named its top dir.
src_unix=$(find "$EXTRACT_DIR" -type d -name "x86_64-unix" | head -n1)
src_win64=$(find "$EXTRACT_DIR" -type d -name "x86_64-windows" | head -n1)
src_win32=$(find "$EXTRACT_DIR" -type d -name "i386-windows" | head -n1)
[[ -d "$src_unix"  ]] || die "x86_64-unix not found in tarball"
[[ -d "$src_win64" ]] || die "x86_64-windows not found in tarball"
[[ -d "$src_win32" ]] || die "i386-windows not found in tarball"

# -- Place DLLs ---------------------------------------------------------------
# For a "builtin" DXMT build we need:
#   - winemetal.so   in <wine>/lib/wine/x86_64-unix/
#   - winemetal.dll  in <wine>/lib/wine/x86_64-windows/ AND prefix/system32
#   - d3d11/dxgi/d3d10core.dll in <wine>/lib/wine/x86_64-windows/
#
# Writing into the Wine bundle means a future `brew upgrade --cask wine-stable`
# will wipe these files, which is fine: rerun this script after upgrading Wine.

install_file() {
    local src=$1 dst=$2
    [[ -f "$src" ]] || die "Missing source file: $src"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    log_ok "Installed $(basename "$dst") -> $dst"
}

install_file "$src_unix/winemetal.so"  "$WINE_LIB_UNIX/winemetal.so"

# 64-bit DXMT pieces — used by native x86_64 Windows programs
for dll in winemetal.dll d3d11.dll dxgi.dll d3d10core.dll; do
    [[ -f "$src_win64/$dll" ]] || die "Tarball missing x86_64 $dll"
    install_file "$src_win64/$dll" "$WINE_LIB_WIN64/$dll"
done
install_file "$src_win64/winemetal.dll" "$PREFIX_SYS32/winemetal.dll"

# 32-bit DXMT pieces — used by 32-bit Unity / older Windows games like
# 幻獣大農場 (MonsterFarm.exe). Without these, Wine's 32-bit builtin d3d11
# stub in syswow64 gets loaded and the game dies at
# "GfxDevice: creating device client" with no further log output.
for dll in winemetal.dll d3d11.dll dxgi.dll d3d10core.dll; do
    [[ -f "$src_win32/$dll" ]] || die "Tarball missing i386 $dll"
    install_file "$src_win32/$dll" "$WINE_LIB_WIN32/$dll"
done
install_file "$src_win32/winemetal.dll" "$PREFIX_SYSWOW64/winemetal.dll"

log_ok "DXMT ${DXMT_TAG} installed (64-bit + 32-bit)"
log_info "DLL overrides are applied at launch time by scripts/launch-steam.sh"
