#!/usr/bin/env bash
#
# 10-add-to-dock.sh — Pin "Steam on M1 Wine.app" to the user's Dock.
#
# The Dock stores its configuration in a binary plist at
# ~/Library/Preferences/com.apple.dock.plist. Rewriting that plist
# by hand is error-prone (the XML embeds CFData, CFURL typing, and
# duplicate tiles if you're not careful), so we use macOS's own
# `defaults` command:
#
#   defaults write com.apple.dock persistent-apps \
#     -array-add <tile-dictionary>
#
# followed by `killall Dock` to make the change visible.
#
# This script is **opt-in**. install.sh prints the invocation but does
# not run it automatically — the Dock is part of the user's
# environment and we don't want to mutate it without consent.
#
# Idempotent: if an entry for the .app is already present, we leave
# it alone rather than stacking duplicates.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_macos_arm64

APP_NAME="Steam on M1 Wine.app"
INSTALL_APP_DIR="${INSTALL_APP_DIR:-$HOME/Applications}"
APP_PATH="$INSTALL_APP_DIR/$APP_NAME"

[[ -d "$APP_PATH" ]] \
    || die "$APP_PATH not found. Run scripts/09-install-macos-app.sh first."

log_step "Pinning $APP_NAME to the Dock"

# Check whether an entry already exists. `defaults read` for
# persistent-apps returns a plist dump; grep for the app's posix path.
if defaults read com.apple.dock persistent-apps 2>/dev/null \
        | grep -q "$APP_PATH"; then
    log_ok "$APP_NAME is already pinned to the Dock; nothing to do"
    exit 0
fi

# Append the tile. The dictionary literal mirrors what the Dock writes
# when you drag an app in from Finder. _CFURLString holds the POSIX
# path; _CFURLStringType=0 means POSIX (as opposed to file://).
defaults write com.apple.dock persistent-apps -array-add "<dict>
    <key>tile-data</key>
    <dict>
        <key>file-data</key>
        <dict>
            <key>_CFURLString</key>
            <string>$APP_PATH</string>
            <key>_CFURLStringType</key>
            <integer>0</integer>
        </dict>
    </dict>
</dict>"

# killall Dock causes macOS to relaunch the Dock process, picking up
# the new persistent-apps array. The Dock restarts almost instantly.
killall Dock

log_ok "Added to Dock; the Dock process was restarted"
log_info "To remove it later: right-click the icon → Options → Remove from Dock"
