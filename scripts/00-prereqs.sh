#!/usr/bin/env bash
#
# 00-prereqs.sh — Verify the host environment before installing anything.
#
# Checks:
#   - macOS + Apple Silicon
#   - macOS version is Tahoe 26 or newer (tested target)
#   - Rosetta 2 is installed (wine-stable binaries are x86_64)
#   - Homebrew is installed at /opt/homebrew
#   - Xcode Command Line Tools are installed
#   - At least 10 GB free on the home volume
#
# This script is read-only. It does not install anything; it exits
# non-zero if a prerequisite is missing so the rest of the pipeline
# can refuse to start.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

log_step "Checking host prerequisites"

# --- macOS + Apple Silicon ---------------------------------------------------
require_macos_arm64
log_ok "Apple Silicon + macOS confirmed"

# --- macOS version ------------------------------------------------------------
os_version=$(sw_vers -productVersion)
os_major=${os_version%%.*}
if (( os_major < 26 )); then
    log_warn "macOS $os_version detected — this project targets macOS 26 (Tahoe) or newer."
    log_warn "Older macOS may work but is untested; proceed at your own risk."
else
    log_ok "macOS $os_version"
fi

# --- Rosetta 2 ----------------------------------------------------------------
if pgrep -q -f oahd; then
    log_ok "Rosetta 2 is running (oahd detected)"
else
    log_warn "Rosetta 2 not detected. Install with:"
    log_warn "    softwareupdate --install-rosetta --agree-to-license"
    die "Rosetta 2 required"
fi

# --- Homebrew -----------------------------------------------------------------
require_homebrew
brew_version=$(brew_arm64 --version | head -n1)
log_ok "Homebrew found: $brew_version"

# --- Xcode Command Line Tools -------------------------------------------------
if xcode-select -p >/dev/null 2>&1; then
    clt_path=$(xcode-select -p)
    log_ok "Xcode tools at $clt_path"
else
    log_warn "Xcode Command Line Tools missing. Install with:"
    log_warn "    xcode-select --install"
    die "Xcode CLT required"
fi

# --- Disk headroom -----------------------------------------------------------
# df -k reports 1 KB blocks; we want GB on the volume that hosts $HOME.
home_avail_kb=$(df -k "$HOME" | awk 'NR==2 {print $4}')
home_avail_gb=$((home_avail_kb / 1024 / 1024))
if (( home_avail_gb < 10 )); then
    die "Less than 10 GB free on \$HOME ($home_avail_gb GB). Free some space and retry."
fi
log_ok "Disk headroom: ${home_avail_gb} GB on \$HOME volume"

# --- Summary -----------------------------------------------------------------
log_step "Prerequisites OK"
cat <<EOS >&2
   macOS version : $os_version
   Architecture  : $(sysctl -n machdep.cpu.brand_string 2>/dev/null) (arm64)
   Homebrew      : $HOMEBREW_PREFIX
   WINEPREFIX    : $WINEPREFIX  (will be created by 02-setup-prefix.sh)
   Wine app      : $WINE_APP    (will be installed by 01-install-wine.sh)
EOS
