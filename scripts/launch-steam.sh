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
patterns='steam\.exe|steamwebhelper|steamservice|wineserver|wine64-preloader|winedevice'
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

# DLL overrides.
#
# The DXMT entries (`dxgi,d3d11,d3d10core=n,b`) were needed only while
# the wrapper asked Chromium to stay GPU-accelerated. In the Step 2
# fallback path the wrapper tells Chromium `--disable-gpu`, so d3d11
# is never called and forcing DXMT's native DLLs only adds noise.
# We leave `bcrypt=b` for BoringSSL hygiene.
export WINEDLLOVERRIDES="bcrypt=b;ncrypt=b"

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

# Clear old log so tailing is unambiguous.
: > "$LOG_FILE"

log_step "Launching Steam"
log_info "Prefix           : $WINEPREFIX"
log_info "Wine binary      : $WINE_BIN"
log_info "WINEDLLOVERRIDES : $WINEDLLOVERRIDES"
log_info "Steam flags      : ${STEAM_ARGS[*]}"
log_info "Log file         : $LOG_FILE"

cd "$WINEPREFIX/drive_c/Program Files (x86)/Steam" \
    || die "Cannot cd into Steam install directory"
nohup arch -x86_64 "$WINE_BIN" \
    "C:\\Program Files (x86)\\Steam\\Steam.exe" \
    "${STEAM_ARGS[@]}" \
    >"$LOG_FILE" 2>&1 &
STEAM_PID=$!
disown
log_ok "Launched Steam (host pid=$STEAM_PID)"

if [[ "${1:-}" == "--detach" ]]; then
    exit 0
fi

log_info "Tailing $LOG_FILE — press Ctrl-C to detach (Steam keeps running)"
tail -f "$LOG_FILE"
