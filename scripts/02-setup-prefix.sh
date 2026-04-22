#!/usr/bin/env bash
#
# 02-setup-prefix.sh — Create (or refresh) the Wine prefix at $WINEPREFIX
# and seed it with Japanese system fonts so Steam UI can render glyphs.
#
# Idempotent: re-running on an existing prefix only runs `wineboot -u`
# (to align the prefix with the installed Wine version) and re-copies
# fonts whose destination file is missing or older than the source.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_wine_installed

log_step "Setting up WINEPREFIX at $WINEPREFIX"

# -- Create or upgrade the prefix ---------------------------------------------
if [[ -d "$WINEPREFIX/drive_c/windows" ]]; then
    log_info "Existing prefix detected — running wineboot -u to align with current Wine"
    wine_run wineboot -u >/dev/null 2>&1 || true
    log_ok "Prefix aligned"
else
    log_info "Creating new prefix"
    wine_run wineboot -i >/dev/null 2>&1 || die "wineboot -i failed"
    log_ok "Prefix created"
fi

# -- Seed Japanese fonts ------------------------------------------------------
#
# Steam's Chromium-based UI renders with whatever the host has in
# C:\windows\Fonts. A fresh Wine prefix ships only Liberation fonts, so
# Japanese characters show as tofu boxes (□). We copy fonts the user
# already owns, so there is no third-party redistribution.

fonts_dir="$WINEPREFIX/drive_c/windows/Fonts"
mkdir -p "$fonts_dir"

# Source list: paths on the host that we try to copy, in priority order.
# Earlier entries take precedence when multiple files cover the same script.
declare -a font_sources=(
    "/System/Library/Fonts/Hiragino Sans GB.ttc"
)

# macOS 14+ may store additional CJK fonts as on-demand MobileAssets.
# Pick up anything we can find — the exact asset hashes change between
# macOS builds, so we globbed them rather than hard-coding.
while IFS= read -r -d '' f; do
    font_sources+=("$f")
done < <(find /System/Library/AssetsV2 -type f \
    \( -iname "YuGothic-*.otf" \
    -o -iname "Osaka.ttf" \
    -o -iname "OsakaMono.ttf" \
    -o -iname "ToppanBunkyuGothicPr6N.ttc" \) -print0 2>/dev/null)

copied=0
skipped=0
for src in "${font_sources[@]}"; do
    [[ -r "$src" ]] || continue
    dst="$fonts_dir/$(basename "$src")"
    if [[ -f "$dst" ]] && [[ ! "$src" -nt "$dst" ]]; then
        skipped=$((skipped + 1))
        continue
    fi
    cp "$src" "$dst"
    copied=$((copied + 1))
done
log_ok "Fonts: $copied copied, $skipped already up to date"

if (( copied == 0 && skipped == 0 )); then
    log_warn "No Japanese fonts found on this host — Steam UI may show tofu."
    log_warn "Install Japanese language support in System Settings to pull them down."
fi

# -- Font substitution registry -----------------------------------------------
#
# Copying .ttc / .otf into C:\windows\Fonts makes them discoverable,
# but logical Windows font names (MS Shell Dlg, MS UI Gothic, Segoe UI …)
# still resolve to Liberation Sans, which has no CJK glyphs. Register
# an explicit mapping so Steam's bootstrap dialog and CEF UI render
# Japanese characters instead of tofu (squares).
FONT_REG="$REPO_ROOT/scripts/assets/japanese-fonts.reg"
if [[ -f "$FONT_REG" ]]; then
    log_info "Applying font substitution registry ($FONT_REG)"
    # regedit is resolved via the Wine installation, run under Rosetta.
    wine_run regedit /S "$(wine_run winepath -w "$FONT_REG" 2>/dev/null | tr -d '\r')" 2>/dev/null \
        || wine_run regedit /S "Z:$FONT_REG" 2>/dev/null \
        || log_warn "regedit import reported a non-zero exit; font mapping may not be applied"
    log_ok "Font substitution registry applied"
else
    log_warn "Font substitution reg file missing: $FONT_REG"
fi

log_ok "Prefix ready at $WINEPREFIX"
