#!/usr/bin/env bash
#
# 08-patch-wine-visibility.sh — Rebuild Wine 11's winemac.so with
# -fvisibility=default and drop it over the Gcenx wine-stable cask install.
#
# Only winemac.so is replaced; wineserver, ntdll.so, and every other file in
# the cask tree are left untouched.
#
# This is step 4 of 4 in the "fixes not available off the shelf" list.
# See docs/building-for-games.md for full context and the complete list.
#
# WARNING: The first run compiles Wine from source. Expect ~30 minutes of
# build time on an M-series Mac. Subsequent runs (sentinel-guarded) complete
# in seconds.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_macos_arm64
require_wine_installed

# -- Overridable paths --------------------------------------------------------

: "${WINE_BUILD_SRC:=$HOME/dev/wine-build/wine}"
: "${WINE_BUILD_BRANCH:=wine-11.0}"

WINE_UNIX_DIR="$WINE_APP/Contents/Resources/wine/lib/wine/x86_64-unix"

# -- Sentinel: already patched? -----------------------------------------------

log_step "Checking if winemac.so is already patched"

installed_so="$WINE_UNIX_DIR/winemac.so"
[[ -f "$installed_so" ]] || die "winemac.so not found: $installed_so"

installed_pub_count=$(nm -g "$installed_so" 2>/dev/null \
    | awk '$2=="T"' \
    | wc -l \
    | tr -d ' ')

if (( installed_pub_count >= 100 )); then
    log_ok "Already patched ($installed_pub_count public symbols in installed winemac.so). Nothing to do."
    exit 0
fi
log_info "Installed winemac.so has $installed_pub_count public symbols (need >= 100); proceeding."

# -- Sentinel: built .so is newer than installed? -----------------------------

built_so="$WINE_BUILD_SRC/build/dlls/winemac.drv/winemac.so"

if [[ -f "$built_so" && "$built_so" -nt "$installed_so" ]]; then
    log_ok "Built winemac.so ($built_so) is newer than installed; skipping to copy step."
    # Jump straight to the copy/verify section below by setting a flag.
    _SKIP_TO_COPY=1
else
    _SKIP_TO_COPY=0
fi

# -- Step 1: Install build-time dependencies ----------------------------------

if (( _SKIP_TO_COPY == 0 )); then
    log_step "Installing build-time dependencies"

    log_warn "This will take roughly 30 minutes to build Wine from source on first run."

    for formula in bison flex gettext mingw-w64 pkg-config freetype; do
        if brew_arm64 list --formula 2>/dev/null | grep -q "^${formula}$"; then
            log_ok "Formula already installed: $formula"
        else
            log_info "Installing $formula"
            brew_arm64 install --quiet "$formula"
            log_ok "Installed $formula"
        fi
    done

    # -- Step 2: Clone or update Wine source ----------------------------------

    log_step "Preparing Wine source ($WINE_BUILD_BRANCH)"

    if [[ ! -d "$WINE_BUILD_SRC/.git" ]]; then
        log_info "Cloning Wine $WINE_BUILD_BRANCH into $WINE_BUILD_SRC"
        mkdir -p "$(dirname "$WINE_BUILD_SRC")"
        git clone --branch "$WINE_BUILD_BRANCH" --depth 1 \
            https://gitlab.winehq.org/wine/wine.git "$WINE_BUILD_SRC" \
            || die "git clone of Wine failed"
        log_ok "Clone complete"
    else
        log_info "Fetching $WINE_BUILD_BRANCH from upstream"
        git -C "$WINE_BUILD_SRC" fetch --depth 1 origin "$WINE_BUILD_BRANCH" \
            || log_warn "git fetch failed; proceeding with local source"
        # fast-forward only; never reset the user's local edits
        git -C "$WINE_BUILD_SRC" merge --ff-only "origin/$WINE_BUILD_BRANCH" 2>/dev/null \
            || log_warn "Wine source tree has local changes; skipping ff-only merge"
        log_ok "Source up to date"
    fi

    # -- Step 3: Configure ----------------------------------------------------

    log_step "Configuring Wine build (out-of-tree)"

    mkdir -p "$WINE_BUILD_SRC/build"

    if [[ ! -f "$WINE_BUILD_SRC/build/Makefile" ]]; then
        log_info "Running configure (arch -x86_64 for mingw-w64 toolchain probing)"
        (
            cd "$WINE_BUILD_SRC/build"
            arch -x86_64 ../configure \
                --enable-win64 \
                --disable-tests \
                CFLAGS='-fvisibility=default -O2 -Wno-error' \
                CXXFLAGS='-fvisibility=default -O2 -Wno-error'
        ) || die "Wine configure failed"
        log_ok "Configure succeeded"
    else
        log_ok "Makefile already present; skipping configure"
    fi

    # -- Step 4: Build winemac.so ---------------------------------------------

    log_step "Building dlls/winemac.drv/winemac.so"

    ncpu=$(sysctl -n hw.logicalcpu)

    log_info "Attempting targeted build (dlls/winemac.drv/winemac.so) with -j${ncpu}"
    if arch -x86_64 make -C "$WINE_BUILD_SRC/build" \
            -j"$ncpu" dlls/winemac.drv/winemac.so 2>&1; then
        log_ok "Targeted build succeeded"
    else
        log_warn "Targeted build failed; falling back to full default make"
        arch -x86_64 make -C "$WINE_BUILD_SRC/build" -j"$ncpu" \
            || die "Full Wine build failed"
        log_ok "Full build succeeded"
    fi
fi

# -- Step 5: Sanity check the built .so ---------------------------------------

log_step "Sanity-checking built winemac.so"

[[ -f "$built_so" ]] \
    || die "Built winemac.so not found after build step: $built_so"

built_pub_count=$(nm -g "$built_so" 2>/dev/null \
    | awk '$2=="T"' \
    | wc -l \
    | tr -d ' ')

if (( built_pub_count < 100 )); then
    die "Built winemac.so has only $built_pub_count public symbols (expected >= 100)." \
        "The -fvisibility=default flag may not have taken effect. Check build logs."
fi
log_ok "Built winemac.so has $built_pub_count public symbols — looks correct."

# -- Step 6: Copy with backup -------------------------------------------------

log_step "Installing patched winemac.so into Wine bundle"

backup="$WINE_UNIX_DIR/winemac.so.gcenx-backup"
if [[ ! -f "$backup" ]]; then
    log_info "Creating backup of Gcenx-shipped winemac.so"
    log_warn "sudo may prompt for your password (Wine bundle is under /Applications)."
    sudo cp "$installed_so" "$backup" \
        || die "Failed to create backup at $backup"
    log_ok "Backup saved: $backup"
else
    log_ok "Backup already exists: $backup"
fi

log_info "Copying patched winemac.so into $WINE_UNIX_DIR"
log_warn "sudo may prompt for your password."
sudo cp "$built_so" "$installed_so" \
    || die "Failed to copy patched winemac.so to $installed_so"
log_ok "Installed patched winemac.so"

# -- Step 7: Final verification -----------------------------------------------

log_step "Verifying installed winemac.so"

final_count=$(nm -g "$installed_so" 2>/dev/null \
    | awk '$2=="T"' \
    | wc -l \
    | tr -d ' ')

if (( final_count < 100 )); then
    die "Installed winemac.so still has only $final_count public symbols after copy." \
        "Something went wrong. Check $installed_so."
fi
log_ok "Installed winemac.so has $final_count public symbols. Patch applied successfully."
