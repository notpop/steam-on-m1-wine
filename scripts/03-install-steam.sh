#!/usr/bin/env bash
#
# 03-install-steam.sh — Download SteamSetup.exe from Valve's CDN and
# run it silently inside our Wine prefix.
#
# Idempotent: exits early if Steam.exe is already present in the prefix.
# Re-run after deleting the prefix to reinstall.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_wine_installed
require_prefix_initialised

STEAM_INSTALL_DIR="$WINEPREFIX/drive_c/Program Files (x86)/Steam"
STEAM_EXE="$STEAM_INSTALL_DIR/steam.exe"

# Official Valve CDN. URL is stable; the installer self-updates on first run.
SETUP_URL="https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe"
SETUP_DEST="${TMPDIR:-/tmp}/SteamSetup.exe"

log_step "Installing Steam inside the Wine prefix"

if [[ -x "$STEAM_EXE" ]]; then
    log_ok "Steam already installed at $STEAM_EXE"
    exit 0
fi

# -- Download the installer ---------------------------------------------------
log_info "Downloading $SETUP_URL"
if ! curl -fL --retry 3 --retry-delay 2 -o "$SETUP_DEST" "$SETUP_URL"; then
    die "Failed to download SteamSetup.exe"
fi

# Sanity check: Nullsoft installer carries an MZ header.
if ! head -c 2 "$SETUP_DEST" | grep -q '^MZ'; then
    die "Downloaded SteamSetup.exe is not a valid PE executable"
fi
log_ok "Downloaded $(wc -c < "$SETUP_DEST" | tr -d ' ') bytes"

# -- Silent install -----------------------------------------------------------
# /S is NSIS's silent flag. The Valve installer honours it.
log_info "Running silent install (this can take 30–90 seconds)"
wine_run "$SETUP_DEST" /S

if [[ ! -x "$STEAM_EXE" ]]; then
    die "Steam.exe did not appear at $STEAM_EXE after install"
fi

size=$(stat -f%z "$STEAM_EXE" 2>/dev/null || echo 0)
log_ok "Steam.exe installed ($size bytes)"

# Leave the installer in TMPDIR — the OS will clean it up eventually,
# and keeping it means re-running this script without network does nothing
# surprising.
