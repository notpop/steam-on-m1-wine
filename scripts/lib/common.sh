#!/usr/bin/env bash
# Shared helpers for steam-on-m1-wine scripts.
#
# Source this file from each script:
#   source "$(dirname "$0")/lib/common.sh"
#
# Provides:
#   - strict mode (set -euo pipefail)
#   - logging helpers (log_info, log_warn, log_error, log_step)
#   - require_cmd / require_macos_arm64 / require_homebrew
#   - WINE / WINEPREFIX / HOMEBREW_PREFIX environment defaults
#   - run_x86_64 (wraps arch -x86_64)
#
# shellcheck shell=bash

set -euo pipefail

# -- Colour handling ----------------------------------------------------------

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
    readonly C_RESET=$'\033[0m'
    readonly C_BOLD=$'\033[1m'
    readonly C_BLUE=$'\033[34m'
    readonly C_GREEN=$'\033[32m'
    readonly C_YELLOW=$'\033[33m'
    readonly C_RED=$'\033[31m'
else
    readonly C_RESET=""
    readonly C_BOLD=""
    readonly C_BLUE=""
    readonly C_GREEN=""
    readonly C_YELLOW=""
    readonly C_RED=""
fi

# -- Logging ------------------------------------------------------------------

_log() {
    local level=$1 color=$2
    shift 2
    local ts
    ts=$(date +%H:%M:%S)
    printf '%s%s [%s]%s %s\n' "$color" "$ts" "$level" "$C_RESET" "$*" >&2
}

log_info()  { _log "INFO"  "$C_BLUE"   "$*"; }
log_ok()    { _log "OK"    "$C_GREEN"  "$*"; }
log_warn()  { _log "WARN"  "$C_YELLOW" "$*"; }
log_error() { _log "ERROR" "$C_RED"    "$*"; }

log_step() {
    printf '\n%s%s== %s ==%s\n' "$C_BOLD" "$C_BLUE" "$*" "$C_RESET" >&2
}

die() {
    log_error "$@"
    exit 1
}

# -- Environment defaults -----------------------------------------------------

: "${HOMEBREW_PREFIX:=/opt/homebrew}"
export HOMEBREW_PREFIX
export PATH="$HOMEBREW_PREFIX/bin:$PATH"

: "${WINE_APP:=/Applications/Wine Stable.app}"
: "${WINE_BIN:=$WINE_APP/Contents/Resources/wine/bin/wine}"
: "${WINESERVER_BIN:=$WINE_APP/Contents/Resources/wine/bin/wineserver}"
: "${WINEPREFIX:=$HOME/.wine-steam}"
export WINE_APP WINE_BIN WINESERVER_BIN WINEPREFIX

# Wine often chats — callers can re-enable by exporting WINEDEBUG before.
: "${WINEDEBUG:=-all}"
export WINEDEBUG

# Repository root (resolved from this file's location).
# shellcheck disable=SC2034
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

# -- Guards -------------------------------------------------------------------

require_cmd() {
    local cmd=$1
    command -v "$cmd" >/dev/null 2>&1 \
        || die "Required command not found in PATH: $cmd"
}

require_macos_arm64() {
    [[ "$(uname -s)" == "Darwin" ]] || die "macOS only (detected $(uname -s))."

    # Apple Silicon reports hw.optional.arm64 = 1 even when the caller shell
    # is running translated under Rosetta, so we check the hardware flag
    # rather than uname -m.
    local is_arm64
    is_arm64=$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)
    [[ "$is_arm64" == "1" ]] \
        || die "Apple Silicon (arm64) required. Intel Macs are not supported."
}

require_homebrew() {
    [[ -x "$HOMEBREW_PREFIX/bin/brew" ]] \
        || die "Homebrew not found at $HOMEBREW_PREFIX. Install from https://brew.sh/"
}

require_wine_installed() {
    [[ -x "$WINE_BIN" ]] \
        || die "Wine not installed at $WINE_BIN. Run scripts/01-install-wine.sh first."
}

require_prefix_initialised() {
    [[ -d "$WINEPREFIX/drive_c/windows" ]] \
        || die "WINEPREFIX not initialised at $WINEPREFIX. Run scripts/02-setup-prefix.sh first."
}

# -- Rosetta-aware helpers ----------------------------------------------------

# brew under /opt/homebrew must run arm64; wine-stable is x86_64 and must
# run via Rosetta. Wrap each explicitly.

brew_arm64() {
    arch -arm64 "$HOMEBREW_PREFIX/bin/brew" "$@"
}

run_x86_64() {
    arch -x86_64 "$@"
}

# Run a wine command in the project's prefix, under Rosetta.
wine_run() {
    WINEPREFIX="$WINEPREFIX" WINEDEBUG="$WINEDEBUG" \
        arch -x86_64 "$WINE_BIN" "$@"
}
