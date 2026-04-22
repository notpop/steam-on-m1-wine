#!/usr/bin/env bash
#
# 06-install-wrapper.sh — Compile the steamwebhelper wrapper from C and
# install it into the Steam directory alongside the renamed real binary.
#
# Steps:
#   1. Ensure Homebrew's mingw-w64 toolchain is available (install on demand)
#   2. Build wrapper/steamwebhelper.exe with the bundled Makefile
#   3. Find each cef.winXXX directory inside Steam's bin tree
#   4. Move the original steamwebhelper.exe to steamwebhelper_real.exe
#      (only the first time), then drop in our wrapper as steamwebhelper.exe
#
# References:
#   docs/references.md — DXMT Issue #141 context
#   wrapper/src/steamwebhelper-wrapper.c — the wrapper's source

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_wine_installed
require_prefix_initialised
require_homebrew

# -- Toolchain ---------------------------------------------------------------
MINGW_BIN="$HOMEBREW_PREFIX/bin/x86_64-w64-mingw32-gcc"
if [[ ! -x "$MINGW_BIN" ]]; then
    log_info "Installing mingw-w64 via Homebrew (required to build the wrapper)"
    brew_arm64 install mingw-w64
fi
[[ -x "$MINGW_BIN" ]] || die "mingw-w64 still missing after install attempt"
log_ok "mingw-w64 available: $($MINGW_BIN --version | head -n1)"

# -- Build --------------------------------------------------------------------
WRAPPER_DIR="$REPO_ROOT/wrapper"
WRAPPER_BIN="$WRAPPER_DIR/steamwebhelper.exe"

log_info "Building wrapper"
make -C "$WRAPPER_DIR" clean >/dev/null 2>&1 || true
make -C "$WRAPPER_DIR" CC="$MINGW_BIN" \
    || die "Wrapper build failed"
[[ -f "$WRAPPER_BIN" ]] || die "Wrapper binary missing after build: $WRAPPER_BIN"
log_ok "Built $WRAPPER_BIN ($(wc -c < "$WRAPPER_BIN" | tr -d ' ') bytes)"

# -- Install into each cef.winXXX dir -----------------------------------------
STEAM_CEF_ROOT="$WINEPREFIX/drive_c/Program Files (x86)/Steam/bin/cef"
if [[ ! -d "$STEAM_CEF_ROOT" ]]; then
    die "Steam CEF directory not found at $STEAM_CEF_ROOT — run 03-install-steam.sh first."
fi

wrapper_size=$(stat -f%z "$WRAPPER_BIN")
wrapper_md5=$(md5 -q "$WRAPPER_BIN")

# Valve's steamwebhelper.exe is multiple megabytes (Chromium bundle).
# Our wrapper is < 200 KB. Anything below the threshold is "wrapper-like";
# anything above is "Valve-like". This classifies past wrapper builds
# correctly even when their MD5 has since drifted.
WRAPPER_SIZE_CEILING=500000  # 500 KB

is_wrapper_like() {
    local path=$1
    [[ -f "$path" ]] || return 1
    local s
    s=$(stat -f%z "$path")
    (( s < WRAPPER_SIZE_CEILING ))
}

installed=0
while IFS= read -r -d '' cef_dir; do
    target="$cef_dir/steamwebhelper.exe"
    real="$cef_dir/steamwebhelper_real.exe"

    if [[ ! -f "$target" ]]; then
        log_warn "$cef_dir has no steamwebhelper.exe; skipping"
        continue
    fi

    # State classification by size:
    #   target Valve + no real            -> first install
    #   target Valve + real Valve         -> refresh both (Steam updated binary)
    #   target Valve + real wrapper       -> heal: swap target into real
    #   target wrapper + real Valve       -> steady state: just refresh target md5
    #   target wrapper + real wrapper     -> Valve binary is LOST. die early.
    #   target wrapper + no real          -> first wrapper install interrupted; die

    if is_wrapper_like "$target"; then
        # target is not Valve's. We must never overwrite real with target
        # in this branch (that was the old bug).
        if [[ ! -f "$real" ]]; then
            die "$cef_dir: steamwebhelper.exe looks like a wrapper but there is no real binary. Valve's original is gone. Re-run scripts/03-install-steam.sh to recover."
        fi
        if is_wrapper_like "$real"; then
            die "$cef_dir: BOTH steamwebhelper.exe AND steamwebhelper_real.exe are wrapper-sized. Valve's original is gone. Re-run scripts/03-install-steam.sh to recover."
        fi
        log_ok "$cef_dir: wrapper already installed (refreshing to pinned build)"
    else
        # target is Valve's (big). Preserve it in real before clobbering.
        if [[ ! -f "$real" ]] || is_wrapper_like "$real"; then
            if [[ -f "$real" ]]; then
                log_warn "$cef_dir: real was wrapper-sized; replacing with current Valve binary"
            else
                log_info "$cef_dir: first install — promoting steamwebhelper.exe to steamwebhelper_real.exe"
            fi
            cp "$target" "$real" || die "Failed to stash Valve binary to $real"
        else
            # real is Valve too. If target is newer (Steam updated), overwrite real.
            target_md5=$(md5 -q "$target")
            real_md5=$(md5 -q "$real")
            if [[ "$target_md5" != "$real_md5" ]]; then
                log_info "$cef_dir: Steam updated steamwebhelper.exe — refreshing stashed copy"
                cp "$target" "$real" || die "Failed to refresh $real"
            else
                log_ok "$cef_dir: real binary already matches current Valve binary"
            fi
        fi
    fi

    # At this point real is guaranteed to be a Valve-sized binary.
    # Safe to install the wrapper.
    cp "$WRAPPER_BIN" "$target" \
        || die "Failed to copy wrapper to $target"
    log_ok "Wrapper installed at $target (ref md5 ${wrapper_md5:0:12}, size ${wrapper_size} B)"
    installed=$((installed + 1))
done < <(find "$STEAM_CEF_ROOT" -maxdepth 1 -type d -name "cef.win*" -print0)

if (( installed == 0 )); then
    die "No cef.winXXX directory found under $STEAM_CEF_ROOT"
fi
log_ok "Wrapper installed in $installed CEF directory/directories"
