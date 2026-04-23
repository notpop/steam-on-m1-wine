#!/usr/bin/env bash
#
# install.sh — End-to-end setup for steam-on-m1-wine.
#
# Default mode (no arguments)
# ---------------------------
# Builds the full D3D11-gaming stack: Wine 11 + Steam + steamwebhelper
# wrapper + DXMT fork build + Wine rebuild with -fvisibility=default
# + macOS .app bundle. After this finishes the user can launch Steam,
# log in, and run D3D11 games through DXMT. Takes ~1 hour on first
# run (LLVM 15 x86_64 build + Wine 11 compile), seconds on re-runs.
#
# --minimal
# ---------
# Stops after scripts/06. Steam UI works; D3D11 games don't. Useful
# for testing the CEF side without waiting on the long builds. The
# user can always run `bash install.sh` later to complete the stack.
#
# Every step is idempotent; safe to re-run at any point.
#
# Env overrides (all optional)
# ----------------------------
#   WINEPREFIX         target prefix directory (default: ~/.wine-steam)
#   INSTALL_APP_DIR    where Steam on M1 Wine.app lands (default: ~/Applications)
#   DXMT_SRC           where the DXMT fork is cloned (default: ~/dev/dxmt)
#   LLVM_PREFIX        where the x86_64 LLVM 15 lives (default: $DXMT_SRC/toolchains/llvm)
#   WINE_BUILD_SRC     where Wine 11.0 source lives (default: ~/dev/wine-build/wine)

set -euo pipefail
cd "$(dirname "$0")"

# shellcheck source=scripts/lib/common.sh
source "scripts/lib/common.sh"
require_macos_arm64

MODE="full"
if [[ "${1:-}" == "--minimal" ]]; then
    MODE="minimal"
elif [[ -n "${1:-}" ]]; then
    die "Unknown argument: $1 (use --minimal, or no arguments for full)"
fi

log_step "steam-on-m1-wine installer ($MODE mode)"
log_info "Prefix            : $WINEPREFIX"
log_info "App install dir   : ${INSTALL_APP_DIR:-$HOME/Applications}"
log_info ""
if [[ "$MODE" == "full" ]]; then
    log_info "Full mode runs scripts/00 through 09 in sequence. On a fresh"
    log_info "machine that means ~1 hour total — mainly an LLVM 15"
    log_info "self-build and a Wine 11 rebuild. Each step is idempotent,"
    log_info "so re-running after a failure just picks up where it left"
    log_info "off."
    log_info ""
    log_info "If you only need the Steam UI (no D3D11 games) and want to"
    log_info "stop after a few minutes, run:  bash install.sh --minimal"
else
    log_info "Minimal mode runs scripts/00 through 06 + 09 only. The Steam"
    log_info "UI will boot; D3D11 games will show transparent windows."
    log_info "Re-run without --minimal to add the DXMT fork + Wine"
    log_info "-fvisibility=default patch."
fi

core_steps=(
    scripts/00-prereqs.sh
    scripts/01-install-wine.sh
    scripts/02-setup-prefix.sh
    scripts/03-install-steam.sh
    scripts/04-install-dxmt.sh
    scripts/05-fix-ssl.sh
    scripts/06-install-wrapper.sh
)

d3d11_steps=(
    scripts/07-build-dxmt-fork.sh
    scripts/08-patch-wine-visibility.sh
)

app_step=scripts/09-install-macos-app.sh

if [[ "$MODE" == "full" ]]; then
    steps=("${core_steps[@]}" "${d3d11_steps[@]}" "$app_step")
else
    steps=("${core_steps[@]}" "$app_step")
fi

for step in "${steps[@]}"; do
    log_step "$(basename "$step")"
    bash "$step" || die "$step failed; fix the error above and re-run install.sh"
done

APP_NAME="Steam on M1 Wine.app"
APP_PATH="${INSTALL_APP_DIR:-$HOME/Applications}/$APP_NAME"

log_step "Done"
log_info ""
log_info "Launch options:"
log_info "  • Double-click $APP_PATH"
log_info "  • or run:  bash scripts/launch-steam.sh --detach"
log_info ""
log_info "Pin to the Dock (recommended):"
log_info "  • Run  open ${INSTALL_APP_DIR:-$HOME/Applications}"
log_info "  • Drag '$APP_NAME' onto your Dock"
log_info "  • Or run  bash scripts/10-add-to-dock.sh  (automated)"
log_info ""
if [[ "$MODE" == "minimal" ]]; then
    log_info "You ran --minimal. D3D11 games will show transparent windows"
    log_info "until you complete the stack:"
    log_info "  bash install.sh         # picks up 07 + 08"
    log_info ""
fi
log_info "Per-game Steam Launch Options (Unity titles):"
log_info "  -force-d3d11-no-singlethreaded -screen-fullscreen 0"
