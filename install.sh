#!/usr/bin/env bash
#
# install.sh — One-shot bootstrap for steam-on-m1-wine.
#
# Idempotent end-to-end setup. Safe to re-run at any point; each step
# short-circuits if its work has already been done.
#
# What it does (in order)
# -----------------------
#   1. 00-prereqs.sh         Verify Rosetta, Homebrew, Xcode CLT
#   2. 01-install-wine.sh    brew install wine-stable + gstreamer
#   3. 02-setup-prefix.sh    Initialise $WINEPREFIX + JP fonts
#   4. 03-install-steam.sh   Fetch & install SteamSetup.exe
#   5. 04-install-dxmt.sh    Stage DXMT v0.74 (still used as a fallback)
#   6. 05-fix-ssl.sh         BCrypt / SSL workarounds
#   7. 06-install-wrapper.sh Build + deploy the steamwebhelper wrapper
#   8. 09-install-macos-app.sh  Drop "Steam on M1 Wine.app" into
#                               ~/Applications for Dock pinning
#
# What it intentionally does NOT do
# ---------------------------------
#   - Does not pin the .app to the Dock. Mutating the Dock's plist
#     without explicit consent is too invasive. The final step prints
#     `open ~/Applications` so the user can drag the app in manually
#     (or run `scripts/10-add-to-dock.sh` if they want it automated).
#   - Does not rebuild the DXMT fork (v0.6 fix). The fork build needs
#     extra toolchains (LLVM 15 cross-build, the 3Shain Wine tarball,
#     meson 1.10) and takes tens of minutes. That is a separate,
#     opt-in step: `scripts/experimental/07-build-dxmt-from-fork.sh`.
#     Until we ship a prebuilt winemetal.so / DXMT fork artefact,
#     anything beyond Steam UI requires running that script by hand.
#
# Usage
# -----
#   bash install.sh
#
# Env overrides (all optional)
# ----------------------------
#   WINEPREFIX         target prefix directory (default: ~/.wine-steam)
#   INSTALL_APP_DIR    where Steam on M1 Wine.app lands (default: ~/Applications)

set -euo pipefail
cd "$(dirname "$0")"

# shellcheck source=scripts/lib/common.sh
source "scripts/lib/common.sh"
require_macos_arm64

log_step "steam-on-m1-wine installer"
log_info "Prefix            : $WINEPREFIX"
log_info "App install dir   : ${INSTALL_APP_DIR:-$HOME/Applications}"
log_info ""
log_info "This will run scripts/00→06 + 09. Any step already completed"
log_info "no-ops out. Total runtime ≈ 10–20 min on a fresh machine,"
log_info "seconds on a re-run."

# Run each step, surfacing its own coloured log lines.
steps=(
    scripts/00-prereqs.sh
    scripts/01-install-wine.sh
    scripts/02-setup-prefix.sh
    scripts/03-install-steam.sh
    scripts/04-install-dxmt.sh
    scripts/05-fix-ssl.sh
    scripts/06-install-wrapper.sh
    scripts/09-install-macos-app.sh
)

for step in "${steps[@]}"; do
    log_step "$(basename "$step")"
    bash "$step" || die "$step failed; fix the error above and re-run install.sh"
done

APP_NAME="Steam on M1 Wine.app"
APP_PATH="${INSTALL_APP_DIR:-$HOME/Applications}/$APP_NAME"

log_step "Done"
log_info ""
log_info "Launch options:"
log_info ""
log_info "  • Double-click $APP_PATH"
log_info "  • or run:  bash scripts/launch-steam.sh --detach"
log_info ""
log_info "Pin to the Dock (recommended):"
log_info "  • Run  open ${INSTALL_APP_DIR:-$HOME/Applications}"
log_info "  • Drag '$APP_NAME' onto your Dock"
log_info "  • Or run  bash scripts/10-add-to-dock.sh  (automated)"
log_info ""
log_info "For D3D11 games (not just Steam UI):"
log_info "  • Follow  docs/building-for-games.md"
log_info "    (DXMT fork build + Wine -fvisibility=default rebuild, ~1 hour)"
