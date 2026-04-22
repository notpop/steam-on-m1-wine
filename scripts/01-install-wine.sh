#!/usr/bin/env bash
#
# 01-install-wine.sh — Install Wine + winetricks + GStreamer via Homebrew.
#
# Installs:
#   - wine-stable  (Gcenx cask, Wine 11.0_1 x86_64)
#   - gstreamer-runtime (dependency of wine-stable; needs sudo for .pkg)
#   - winetricks   (Homebrew formula)
#
# Removes the quarantine xattr from Wine Stable.app so macOS Gatekeeper
# doesn't SIGKILL the unsigned binary on exec.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_macos_arm64
require_homebrew

WINE_CASK="wine-stable"
WINETRICKS_FORMULA="winetricks"

log_step "Installing Wine + winetricks"

# -- Tap Gcenx (if not already) -----------------------------------------------
# wine-stable lives in the official Homebrew Cask repo, so no extra tap is
# strictly required. We keep this block explicit so the script documents
# the trust boundary.
if ! brew_arm64 list --cask | grep -q "^${WINE_CASK}$"; then
    log_info "Installing cask ${WINE_CASK}"
    # gstreamer-runtime (pulled in as a dependency) invokes the system
    # installer and will prompt for sudo in the interactive terminal.
    brew_arm64 install --cask "$WINE_CASK"
else
    log_ok "Cask ${WINE_CASK} already installed"
fi

# -- winetricks ---------------------------------------------------------------
if ! brew_arm64 list --formula | grep -q "^${WINETRICKS_FORMULA}$"; then
    log_info "Installing formula ${WINETRICKS_FORMULA}"
    brew_arm64 install "$WINETRICKS_FORMULA"
else
    log_ok "Formula ${WINETRICKS_FORMULA} already installed"
fi

# -- Gatekeeper quarantine ----------------------------------------------------
# wine-stable is an unsigned/ad-hoc-signed x86_64 bundle. Without removing
# the quarantine xattr, macOS kills wine on launch with exit code 137.
if [[ ! -d "$WINE_APP" ]]; then
    die "Wine Stable.app not found after install: $WINE_APP"
fi

if xattr -l "$WINE_APP" 2>/dev/null | grep -q com.apple.quarantine; then
    log_info "Removing com.apple.quarantine from $WINE_APP"
    xattr -dr com.apple.quarantine "$WINE_APP"
    log_ok "Quarantine xattr cleared"
else
    log_ok "No quarantine xattr on $WINE_APP"
fi

# -- Smoke test ---------------------------------------------------------------
log_info "Smoke-testing Wine binary"
wine_version=$(run_x86_64 "$WINE_BIN" --version 2>&1 || true)
if [[ "$wine_version" =~ ^wine- ]]; then
    log_ok "Wine responds: $wine_version"
else
    die "Wine smoke test failed. Output: $wine_version"
fi

log_ok "Wine + winetricks install complete"
