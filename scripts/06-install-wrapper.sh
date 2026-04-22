#!/usr/bin/env bash
#
# 06-install-wrapper.sh — Compile the steamwebhelper wrapper from C and
# install it into the Steam directory alongside the renamed real binary.
#
# Steps:
#   1. Ensure Homebrew's mingw-w64 toolchain is available (install on demand)
#   2. Build wrapper/steamwebhelper.exe with the bundled Makefile
#   3. Find each cef.winXXX directory inside Steam's bin tree
#   4. Move the original steamwebhelper.exe to steamwebhelper_real.exe
#      (only the first time), then drop in our wrapper as steamwebhelper.exe
#
# References:
#   docs/references.md — DXMT Issue #141 context
#   wrapper/src/steamwebhelper-wrapper.c — the wrapper's source

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_wine_installed
require_prefix_initialised
require_homebrew

# -- Toolchain ---------------------------------------------------------------
MINGW_BIN="$HOMEBREW_PREFIX/bin/x86_64-w64-mingw32-gcc"
if [[ ! -x "$MINGW_BIN" ]]; then
    log_info "Installing mingw-w64 via Homebrew (required to build the wrapper)"
    brew_arm64 install mingw-w64
fi
[[ -x "$MINGW_BIN" ]] || die "mingw-w64 still missing after install attempt"
log_ok "mingw-w64 available: $($MINGW_BIN --version | head -n1)"

# -- Build --------------------------------------------------------------------
WRAPPER_DIR="$REPO_ROOT/wrapper"
WRAPPER_BIN="$WRAPPER_DIR/steamwebhelper.exe"

log_info "Building wrapper"
make -C "$WRAPPER_DIR" clean >/dev/null 2>&1 || true
make -C "$WRAPPER_DIR" CC="$MINGW_BIN" \
    || die "Wrapper build failed"
[[ -f "$WRAPPER_BIN" ]] || die "Wrapper binary missing after build: $WRAPPER_BIN"
log_ok "Built $WRAPPER_BIN ($(wc -c < "$WRAPPER_BIN" | tr -d ' ') bytes)"

# -- Install into each cef.winXXX dir -----------------------------------------
STEAM_CEF_ROOT="$WINEPREFIX/drive_c/Program Files (x86)/Steam/bin/cef"
if [[ ! -d "$STEAM_CEF_ROOT" ]]; then
    die "Steam CEF directory not found at $STEAM_CEF_ROOT — run 03-install-steam.sh first."
fi

installed=0
while IFS= read -r -d '' cef_dir; do
    target="$cef_dir/steamwebhelper.exe"
    real="$cef_dir/steamwebhelper_real.exe"

    if [[ ! -f "$target" ]]; then
        log_warn "$cef_dir has no steamwebhelper.exe; skipping"
        continue
    fi

    # Detect: is the currently-installed steamwebhelper.exe our wrapper, or Valve's?
    # Our wrapper is ~30–80 KB, Valve's is several MB. Use size as a rough
    # proxy, backed up by checking for the real binary next to it.
    current_size=$(stat -f%z "$target" 2>/dev/null || echo 0)
    if [[ -f "$real" ]] && (( current_size < 500000 )); then
        log_ok "$cef_dir already has wrapper installed; refreshing"
    else
        log_info "$cef_dir: renaming steamwebhelper.exe -> steamwebhelper_real.exe"
        mv "$target" "$real" \
            || die "Failed to rename $target to $real"
    fi

    cp "$WRAPPER_BIN" "$target" \
        || die "Failed to copy wrapper to $target"
    log_ok "Wrapper installed at $target"
    installed=$((installed + 1))
done < <(find "$STEAM_CEF_ROOT" -maxdepth 1 -type d -name "cef.win*" -print0)

if (( installed == 0 )); then
    die "No cef.winXXX directory found under $STEAM_CEF_ROOT"
fi
log_ok "Wrapper installed in $installed CEF directory/directories"
