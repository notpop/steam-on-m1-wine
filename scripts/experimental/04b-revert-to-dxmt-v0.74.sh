#!/usr/bin/env bash
#
# 04b-revert-to-dxmt-v0.74.sh — Restore the pinned DXMT v0.74 DLLs
# from the backup that `04b-install-dxmt-nightly.sh` captured.
#
# Use when a nightly made things worse and you want the known-good
# baseline back without re-running `brew upgrade --cask wine-stable`.

# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
require_wine_installed
require_prefix_initialised

BACKUP_DIR="$REPO_ROOT/vendor/dxmt-v074-backup"
WINE_LIB_UNIX="$WINE_APP/Contents/Resources/wine/lib/wine/x86_64-unix"
WINE_LIB_WIN64="$WINE_APP/Contents/Resources/wine/lib/wine/x86_64-windows"
WINE_LIB_WIN32="$WINE_APP/Contents/Resources/wine/lib/wine/i386-windows"
PREFIX_SYS32="$WINEPREFIX/drive_c/windows/system32"
PREFIX_SYSWOW64="$WINEPREFIX/drive_c/windows/syswow64"

log_step "Reverting to DXMT v0.74 baseline"

[[ -d "$BACKUP_DIR" ]] \
    || die "No backup found at $BACKUP_DIR. Run scripts/04-install-dxmt.sh for a fresh v0.74 install."

cp "$BACKUP_DIR/winemetal.so" "$WINE_LIB_UNIX/winemetal.so"
for dll in winemetal.dll d3d11.dll dxgi.dll d3d10core.dll; do
    cp "$BACKUP_DIR/x86_64-windows/$dll" "$WINE_LIB_WIN64/$dll"
    cp "$BACKUP_DIR/i386-windows/$dll"   "$WINE_LIB_WIN32/$dll"
done
cp "$BACKUP_DIR/x86_64-windows/winemetal.dll" "$PREFIX_SYS32/winemetal.dll"
cp "$BACKUP_DIR/i386-windows/winemetal.dll"   "$PREFIX_SYSWOW64/winemetal.dll"

log_ok "DXMT v0.74 baseline restored"
