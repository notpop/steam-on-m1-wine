#!/usr/bin/env bash
#
# launch-steam.sh — Start Steam inside the prefix with the flag set
# and DLL overrides that this project has verified.
#
# Steps:
#   1. Kill any lingering Steam / Wine processes from a previous session
#      (so the new one is not reduced to --silent by single-instance guard)
#   2. Wipe Chromium's SingletonLock (left over by crashes)
#   3. Launch Steam with DXMT-friendly DLL overrides and a set of
#      CEF flags that have been validated on Apple Silicon + wine-stable
#
# Usage:
#   scripts/launch-steam.sh            # attach and tail Steam's log
#   scripts/launch-steam.sh --detach   # fire-and-forget, just print paths

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_wine_installed
require_prefix_initialised

STEAM_EXE="$WINEPREFIX/drive_c/Program Files (x86)/Steam/Steam.exe"
[[ -x "$STEAM_EXE" ]] || die "Steam.exe not found. Run scripts/03-install-steam.sh first."

HTMLCACHE="$WINEPREFIX/drive_c/users/$USER/AppData/Local/Steam/htmlcache"
LOG_FILE="${STEAM_LAUNCH_LOG:-${TMPDIR:-/tmp}/steam-on-m1-wine.log}"

# -- 1. Stop lingering processes ---------------------------------------------
log_step "Stopping any running Steam / Wine processes"
patterns='steam\.exe|steamwebhelper|steamservice|wineserver|wine64-preloader|winedevice|explorer\.exe'
to_kill=$(pgrep -f "$patterns" || true)
if [[ -n "$to_kill" ]]; then
    # shellcheck disable=SC2086 # intentional word-split: multiple PIDs
    kill -9 $to_kill 2>/dev/null || true
    sleep 2
fi
still=$(pgrep -f "$patterns" || true)
if [[ -z "$still" ]]; then
    log_ok "All previous processes cleared"
else
    log_warn "These processes survived kill: $still"
fi

# -- 2. Purge Chromium SingletonLock -----------------------------------------
# When Steam crashes on Wine, Chromium leaves SingletonLock* and Singleton*
# files behind; the next launch then trips the single-instance guard and
# falls back to --silent (no visible window).
if [[ -d "$HTMLCACHE" ]]; then
    find "$HTMLCACHE" -maxdepth 2 \
        \( -name "Singleton*" -o -name "*.lock" -o -name "CrashpadMetrics*.pma" \) \
        -delete 2>/dev/null || true
    log_ok "Chromium locks purged"
fi

# -- 2b. Defensive: re-deploy the steamwebhelper wrapper ----------------------
# Steam runs a checksum verification during boot that restores the original
# helper binary, wiping our wrapper. This happens silently so the next
# launch would otherwise fall back to the black-window regime. We re-run
# scripts/06-install-wrapper.sh whenever we detect the wrapper has been
# evicted from any of the cef.winXXX directories.
WRAPPER_BIN="$REPO_ROOT/wrapper/steamwebhelper.exe"
if [[ -f "$WRAPPER_BIN" ]]; then
    wrapper_md5=$(md5 -q "$WRAPPER_BIN")
    wrapper_needs_redeploy=0
    while IFS= read -r -d '' cef_dir; do
        target_md5=$(md5 -q "$cef_dir/steamwebhelper.exe" 2>/dev/null || echo "")
        if [[ "$target_md5" != "$wrapper_md5" ]]; then
            wrapper_needs_redeploy=1
            log_warn "Wrapper missing/overwritten in $(basename "$cef_dir")"
        fi
    done < <(find "$WINEPREFIX/drive_c/Program Files (x86)/Steam/bin/cef" \
        -maxdepth 1 -type d -name "cef.win*" -print0 2>/dev/null)

    if (( wrapper_needs_redeploy == 1 )); then
        log_info "Re-deploying wrapper via scripts/06-install-wrapper.sh"
        "$REPO_ROOT/scripts/06-install-wrapper.sh" >/dev/null \
            || die "Wrapper re-deployment failed"
        log_ok "Wrapper redeployed"
    else
        log_ok "Wrapper integrity verified in all CEF directories"
    fi
else
    log_warn "Compiled wrapper missing at $WRAPPER_BIN — run scripts/06-install-wrapper.sh"
fi

# -- 2c. Scrub the DISABLEDXMAXIMIZEDWINDOWEDMODE AppCompat token --------------
# Steam tags most DirectX games it installs with this Windows compatibility
# layer. On real Windows it tells DXGI to refuse "maximized windowed mode"
# so the app goes exclusive-fullscreen. Wine's macdrv honours the hint
# (indirectly) and routes the NSWindow into macOS's native fullscreen
# space, which is what makes games seize the whole display and prevents
# coexistence with other macOS windows even when we already opened the
# Wine session inside a `/desktop=` virtual desktop. Strip the token so
# Unity/D3D11 titles can stay windowed.
USER_REG="$WINEPREFIX/user.reg"
if [[ -f "$USER_REG" ]]; then
    if grep -q 'DISABLEDXMAXIMIZEDWINDOWEDMODE' "$USER_REG"; then
        python3 - "$USER_REG" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='surrogateescape') as f:
    data = f.read()
# Value lines look like:
#   "C:\\...\\MonsterFarm.exe"="~ DISABLEDXMAXIMIZEDWINDOWEDMODE"
# Drop the token (and the leading "~ " if it is the only entry) while
# leaving any other compat layers the user may genuinely want intact.
pattern = re.compile(r'"([^"]+\.exe)"="([^"]*)"')
changed = False
def fix(m):
    global changed
    value = m.group(2)
    if 'DISABLEDXMAXIMIZEDWINDOWEDMODE' not in value:
        return m.group(0)
    tokens = [t for t in value.split() if t and t != 'DISABLEDXMAXIMIZEDWINDOWEDMODE']
    # The leading "~" is the AppCompat "USER" marker. Keep it only if
    # other layers remain.
    if tokens == ['~']:
        new = ''
    else:
        new = ' '.join(tokens)
    changed = True
    return f'"{m.group(1)}"="{new}"'
new = pattern.sub(fix, data)
# If an .exe mapped to an empty value after the scrub, drop the line
# entirely so we don't leave noise behind.
new = re.sub(r'\n"[^"]+\.exe"=""\n', '\n', new)
if changed:
    with open(path, 'w', encoding='utf-8', errors='surrogateescape') as f:
        f.write(new)
PYEOF
        log_ok "Stripped DISABLEDXMAXIMIZEDWINDOWEDMODE from AppCompat layers"
    fi

    # -- 2d. Wine Mac Driver: allow the virtual desktop window to be moved ---
    # macdrv's `AllowImmovableWindows` defaults to true, which freezes the
    # NSWindow in place whenever Wine considers the window "disabled" or
    # "maximized" — exactly the state the `/desktop=` virtual desktop is in.
    # Set it to "n" so the user can drag the Wine window around macOS.
    # (dlls/winemac.drv/macdrv_main.c: `allow_immovable_windows = true`)
    if ! grep -q '"AllowImmovableWindows"' "$USER_REG"; then
        python3 - "$USER_REG" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='surrogateescape') as f:
    data = f.read()
section_re = re.compile(r'^\[Software\\\\Wine\\\\Mac Driver\][^\n]*\n', re.MULTILINE)
m = section_re.search(data)
if m:
    # Section exists — append the key just after its header.
    insert = '"AllowImmovableWindows"="n"\n'
    data = data[:m.end()] + insert + data[m.end():]
else:
    # Create the section.
    data = data.rstrip() + '\n\n[Software\\\\Wine\\\\Mac Driver]\n"AllowImmovableWindows"="n"\n'
with open(path, 'w', encoding='utf-8', errors='surrogateescape') as f:
    f.write(data)
PYEOF
        log_ok "Set AllowImmovableWindows=n (virtual desktop window becomes draggable)"
    fi
fi

# -- 3. Build launch environment ---------------------------------------------
#
# WINEDLLOVERRIDES (reference: DXMT install guide)
#   dxgi, d3d11, d3d10core  -> native first, then builtin ("n,b")
#   These are the DXMT DLLs we installed in 04-install-dxmt.sh.
#
# Steam / CEF flags we pass
#   -no-cef-sandbox   Chromium's sandbox relies on Windows low-integrity
#                     tokens that Wine does not model on macOS. Disabling
#                     it lets the browser process start.
#
# What we deliberately do NOT pass
#   -cef-force-sw-gl / -cef-disable-d3d11 : these bypass DXMT entirely,
#      returning us to the black-window regime. They belong in an
#      emergency "DXMT is broken" debug runbook, not the default launch.
#
# The --in-process-gpu flag that DXMT requires is injected by the wrapper
# installed at scripts/06-install-wrapper.sh; it must be applied to
# steamwebhelper.exe, not to steam.exe.

export WINEPREFIX
export WINEDEBUG

# DLL overrides — hybrid configuration.
#
#   dxgi,d3d11,d3d10core=n,b
#     Keep DXMT in the override chain for *games*. Chromium's CEF
#     browser gets its own `--disable-gpu` (passed through the
#     steamwebhelper wrapper) so CEF never creates a D3D11 device
#     and DXMT never fires on its codepath. But Unreal / Unity
#     titles and anything else that calls CreateDevice directly
#     still needs DXMT to translate D3D11 to Metal — otherwise
#     those games die with "Failed to initialize graphics /
#     DirectX 11" at launch.
#
#   bcrypt=b;ncrypt=b
#     Force Wine's builtin BCrypt/NCrypt so Wine 11.0's stubs do
#     not collide with Chromium BoringSSL on Apple Silicon.
#
#   gameoverlayrenderer,gameoverlayrenderer64=d
#     Hard-disable Steam's in-game overlay DLLs. The overlay checkbox
#     in the game properties only stops the UI; the DLL still gets
#     injected into child processes and hooks D3D11. On Wine/DXMT
#     that hook makes the target game deadlock in CreateDevice before
#     Unity's `[Physics::Module]` log line. Turning the DLL into a
#     disabled override stops Wine from loading it at all.
export WINEDLLOVERRIDES="dxgi,d3d11,d3d10core=n,b;bcrypt=b;ncrypt=b;gameoverlayrenderer,gameoverlayrenderer64=d"

# Steam flag set, validated on this hardware:
#   -no-cef-sandbox       Chromium sandbox relies on Windows integrity
#                         tokens Wine doesn't model. Must be disabled.
#   -cef-single-process   Consolidate browser / GPU / renderer into a
#                         single process. Steam-level equivalent of
#                         Chromium --single-process. Sidesteps DXMT's
#                         cross-process swapchain limit (Issue #141).
#   -noverifyfiles        Disable Steam's executable-checksum integrity
#                         check. Without this flag Steam rewrites our
#                         wrapper binary back to Valve's original on every
#                         launch (bootstrap_log reports
#                         "Verifying all executable checksums"
#                         shortly after startup).
STEAM_ARGS=(
    -no-cef-sandbox
    -cef-single-process
    -noverifyfiles
)

# Virtual-desktop wrapper.
#
# Without this, Wine's macdrv hands each Win32 top-level window straight
# to AppKit, so any game that asks for fullscreen takes over the whole
# display. Wrapping Steam (and everything it spawns) inside a single
# Wine `explorer.exe /desktop=NAME,WxH` virtual desktop collapses the
# whole Wine session into one macOS window and prevents games from
# punching into native fullscreen space.
#
# Sizing: Wine's virtual-desktop window is `WS_POPUP` / borderless by
# construction (see dlls/winemac.drv/cocoa_window.m), so macOS gives it
# no title bar. That means the user cannot drag it around — wherever we
# place it is where it stays for the session. The only sensible default
# is therefore "as big as the usable display", which we detect here via
# AppleScript on the Finder (it already excludes the menu bar).
#
# Overrides:
#   WINE_VIRTUAL_DESKTOP=1024x768   explicit resolution
#   WINE_VIRTUAL_DESKTOP=auto       re-detect (same as unset)
#   WINE_VIRTUAL_DESKTOP=""         opt out entirely (Wine creates
#                                   per-window NSWindows again)
#
# Scope: `/desktop=NAME` only applies to this explorer.exe and its
# descendants, so unrelated Wine prefixes / apps are untouched.
WINE_VIRTUAL_DESKTOP_NAME="${WINE_VIRTUAL_DESKTOP_NAME:-steam-on-m1-wine}"

detect_display_size() {
    # Finder's desktop window bounds return "0, 0, WIDTH, HEIGHT" in
    # logical (not Retina-physical) pixels and already exclude the
    # macOS menu bar, which is exactly what Wine's virtual desktop
    # wants to fill.
    local bounds width height
    bounds=$(osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null || true)
    if [[ "$bounds" =~ ,[[:space:]]*([0-9]+),[[:space:]]*([0-9]+)$ ]]; then
        width="${BASH_REMATCH[1]}"
        height="${BASH_REMATCH[2]}"
        if [[ "$width" -gt 0 && "$height" -gt 0 ]]; then
            echo "${width}x${height}"
            return 0
        fi
    fi
    # Fallback to a Retina-13" default if detection fails.
    echo "1440x900"
}

if [[ -z "${WINE_VIRTUAL_DESKTOP+x}" || "${WINE_VIRTUAL_DESKTOP:-}" == "auto" ]]; then
    WINE_VIRTUAL_DESKTOP="$(detect_display_size)"
fi

# Clear old log so tailing is unambiguous.
: > "$LOG_FILE"

log_step "Launching Steam"
log_info "Prefix           : $WINEPREFIX"
log_info "Wine binary      : $WINE_BIN"
log_info "WINEDLLOVERRIDES : $WINEDLLOVERRIDES"
log_info "Steam flags      : ${STEAM_ARGS[*]}"
if [[ -n "$WINE_VIRTUAL_DESKTOP" ]]; then
    log_info "Virtual desktop  : ${WINE_VIRTUAL_DESKTOP_NAME} @ ${WINE_VIRTUAL_DESKTOP}"
else
    log_info "Virtual desktop  : disabled"
fi
log_info "Log file         : $LOG_FILE"

cd "$WINEPREFIX/drive_c/Program Files (x86)/Steam" \
    || die "Cannot cd into Steam install directory"
if [[ -n "$WINE_VIRTUAL_DESKTOP" ]]; then
    nohup arch -x86_64 "$WINE_BIN" \
        explorer.exe "/desktop=${WINE_VIRTUAL_DESKTOP_NAME},${WINE_VIRTUAL_DESKTOP}" \
        "C:\\Program Files (x86)\\Steam\\Steam.exe" \
        "${STEAM_ARGS[@]}" \
        >"$LOG_FILE" 2>&1 &
else
    nohup arch -x86_64 "$WINE_BIN" \
        "C:\\Program Files (x86)\\Steam\\Steam.exe" \
        "${STEAM_ARGS[@]}" \
        >"$LOG_FILE" 2>&1 &
fi
STEAM_PID=$!
disown
log_ok "Launched Steam (host pid=$STEAM_PID)"

if [[ "${1:-}" == "--detach" ]]; then
    exit 0
fi

log_info "Tailing $LOG_FILE — press Ctrl-C to detach (Steam keeps running)"
tail -f "$LOG_FILE"
