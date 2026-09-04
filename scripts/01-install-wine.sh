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
install_wine_from_gcenx_tarball() {
    # Gcenx publishes the same builds as plain tarballs, with an identical
    # bundle layout (Contents/Resources/wine/bin/wine), so unpacking one into
    # $HOME gives us a working Wine without the cask.
    local url="https://github.com/Gcenx/macOS_Wine_builds/releases/download/${WINE_FALLBACK_VERSION}/wine-staging-${WINE_FALLBACK_VERSION}-osx64.tar.xz"

    if [[ -x "${WINE_FALLBACK_APP}/Contents/Resources/wine/bin/wine" ]]; then
        log_ok "Gcenx Wine ${WINE_FALLBACK_VERSION} already at ${WINE_FALLBACK_APP}"
        return 0
    fi

    log_info "Downloading wine-staging ${WINE_FALLBACK_VERSION} from Gcenx"
    mkdir -p "$WINE_FALLBACK_ROOT"
    curl -fL --retry 5 --retry-delay 1 "$url" | tar xJf - -C "$WINE_FALLBACK_ROOT" \
        || die "Could not download or unpack ${url}"

    [[ -x "${WINE_FALLBACK_APP}/Contents/Resources/wine/bin/wine" ]] \
        || die "Wine binary not found after unpacking into ${WINE_FALLBACK_ROOT}"

    log_ok "Installed Gcenx Wine at ${WINE_FALLBACK_APP}"
}

if brew_arm64 list --cask | grep -q "^${WINE_CASK}$"; then
    log_ok "Cask ${WINE_CASK} already installed"
else
    log_info "Installing cask ${WINE_CASK}"
    # gstreamer-runtime (pulled in as a dependency) invokes the system
    # installer and will prompt for sudo in the interactive terminal.
    #
    # Homebrew disabled wine-stable on 2026-09-01 because it does not pass the
    # macOS Gatekeeper check, which used to abort this script outright. Note
    # `brew info --cask` still succeeds for a disabled cask, so the only
    # reliable check is attempting the install. Falling back on any failure
    # also covers the cask being renamed or removed later.
    if ! brew_arm64 install --cask "$WINE_CASK"; then
        log_warn "Cask ${WINE_CASK} could not be installed (disabled or removed upstream)"
        install_wine_from_gcenx_tarball
    fi
fi

# Which of the two is present is only known now, so re-resolve WINE_APP.
resolve_wine_app

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
    die "Wine app bundle not found after install: $WINE_APP"
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
