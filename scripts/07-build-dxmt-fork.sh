#!/usr/bin/env bash
#
# 07-build-dxmt-fork.sh — Automated one-shot build of the DXMT fork.
#
# Automated one-shot sibling of experimental/07-build-dxmt-from-fork.sh.
# Call this from install.sh; use the experimental version if you want
# to drive the prerequisites manually.
#
# What this script does (all steps are idempotent)
# -------------------------------------------------
# 1. Installs missing Homebrew packages (meson, ninja, bison, flex,
#    cmake, gettext, mingw-w64, wget).
# 2. Pins meson to 1.10.x via pip if the system meson is 1.11+.
# 3. Clones or updates the DXMT fork at $DXMT_SRC.
# 4. Builds an x86_64 LLVM 15 static library tree at $LLVM_PREFIX
#    (first run takes ~30 minutes).
# 5. Downloads the 3Shain Wine toolchain tarball into
#    $DXMT_SRC/toolchains/wine.
# 6. Ensures the Xcode Metal toolchain component is installed.
# 7. Runs meson setup + compile for 64-bit and 32-bit DXMT.
# 8. Stages the built artefacts (winemetal.so, DLLs) into the Wine
#    bundle and prefix.
#
# Environment overrides
# ---------------------
#   DXMT_SRC      Path to DXMT source checkout   (default: ~/dev/dxmt)
#   LLVM_PREFIX   x86_64 LLVM install root        (default: $DXMT_SRC/toolchains/llvm)
#   MESON         meson binary to use             (auto-selected by step 2)

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_wine_installed
require_prefix_initialised

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

DXMT_SRC="${DXMT_SRC:-$HOME/dev/dxmt}"
LLVM_PREFIX="${LLVM_PREFIX:-$DXMT_SRC/toolchains/llvm}"
WINE_TOOLCHAIN="${WINE_TOOLCHAIN:-$DXMT_SRC/toolchains/wine}"

WINE_LIB_UNIX="$WINE_APP/Contents/Resources/wine/lib/wine/x86_64-unix"
WINE_LIB_WIN64="$WINE_APP/Contents/Resources/wine/lib/wine/x86_64-windows"
WINE_LIB_WIN32="$WINE_APP/Contents/Resources/wine/lib/wine/i386-windows"
PREFIX_SYS32="$WINEPREFIX/drive_c/windows/system32"
PREFIX_SYSWOW64="$WINEPREFIX/drive_c/windows/syswow64"

DXMT_FORK_URL="https://github.com/notpop/dxmt.git"
DXMT_FORK_BRANCH="debug/present-path-tracing"
LLVM_SRC_DIR="$DXMT_SRC/toolchains/llvm-src"
LLVM_VERSION_TAG="llvmorg-15.0.7"
WINE_TARBALL_URL="https://github.com/3Shain/wine/releases/download/v8.16-3shain/wine.tar.gz"

# ---------------------------------------------------------------------------
# Step 1 — Homebrew tooling
# ---------------------------------------------------------------------------

log_step "Step 1: Homebrew packages"

_brew_ensure() {
    local pkg=$1
    if brew_arm64 list --formula "$pkg" >/dev/null 2>&1; then
        log_info "$pkg already installed — skipping"
    else
        log_info "Installing $pkg"
        brew_arm64 install "$pkg"
        log_ok "$pkg installed"
    fi
}

for _pkg in meson ninja bison flex cmake gettext mingw-w64 wget; do
    _brew_ensure "$_pkg"
done

# ---------------------------------------------------------------------------
# Step 2 — Pin meson to 1.10.x if the system version is 1.11+
# ---------------------------------------------------------------------------

log_step "Step 2: meson version check"

# Default: use whatever brew installed.
MESON="${MESON:-$HOMEBREW_PREFIX/bin/meson}"

_meson_major_minor() {
    # Prints "MAJOR.MINOR" as two integers separated by space: "1 10"
    "$1" --version 2>/dev/null \
        | head -n1 \
        | sed 's/^[^0-9]*//' \
        | awk -F. '{print $1, $2}'
}

if [[ -x "$MESON" ]]; then
    read -r _meson_maj _meson_min <<< "$(_meson_major_minor "$MESON")"
    log_info "System meson version: ${_meson_maj}.${_meson_min}"

    # DXMT's meson.build is incompatible with meson 1.11+.
    if (( _meson_maj > 1 || ( _meson_maj == 1 && _meson_min >= 11 ) )); then
        log_warn "meson ${_meson_maj}.${_meson_min} is too new for DXMT (need 1.10.x)."
        log_warn "Pinning to meson==1.10.1 via pip --user."
        python3 -m pip install --user 'meson==1.10.1' --quiet

        # Derive the user-base bin directory at runtime so it works on
        # any Python 3 minor version.
        _user_base=$(python3 -m site --user-base)
        MESON="$_user_base/bin/meson"
        export MESON

        if [[ ! -x "$MESON" ]]; then
            die "pip installed meson==1.10.1 but $MESON is not executable."
        fi
        read -r _new_maj _new_min <<< "$(_meson_major_minor "$MESON")"
        log_ok "Using pinned meson ${_new_maj}.${_new_min} at $MESON"
    else
        log_ok "meson ${_meson_maj}.${_meson_min} is compatible — no pin needed"
        export MESON
    fi
else
    die "meson not found at $MESON after brew install. Set MESON to the correct path."
fi

# ---------------------------------------------------------------------------
# Step 3 — DXMT clone / update
# ---------------------------------------------------------------------------

log_step "Step 3: DXMT source tree at $DXMT_SRC"

if [[ ! -d "$DXMT_SRC" ]]; then
    log_info "Cloning $DXMT_FORK_URL ($DXMT_FORK_BRANCH)"
    git clone --branch "$DXMT_FORK_BRANCH" "$DXMT_FORK_URL" "$DXMT_SRC"
    log_ok "Clone complete"
else
    log_info "Existing clone found — fetching $DXMT_FORK_BRANCH"
    git -C "$DXMT_SRC" fetch origin "$DXMT_FORK_BRANCH"

    # Only fast-forward if the working tree is clean.
    if git -C "$DXMT_SRC" diff --quiet && git -C "$DXMT_SRC" diff --cached --quiet; then
        git -C "$DXMT_SRC" checkout "$DXMT_FORK_BRANCH"
        git -C "$DXMT_SRC" merge --ff-only "origin/$DXMT_FORK_BRANCH" \
            || log_warn "Fast-forward failed (diverged?). Using existing local HEAD."
        log_ok "Updated to origin/$DXMT_FORK_BRANCH"
    else
        log_warn "Uncommitted changes detected in $DXMT_SRC — skipping merge."
        log_warn "Commit or stash your changes and re-run to pull upstream updates."
    fi
fi

log_info "Updating git submodules"
git -C "$DXMT_SRC" submodule update --init --recursive
log_ok "Submodules ready"

# ---------------------------------------------------------------------------
# Step 4 — x86_64 LLVM 15 at $LLVM_PREFIX
# ---------------------------------------------------------------------------

log_step "Step 4: x86_64 LLVM 15 at $LLVM_PREFIX"

# Sentinel: the main static library exists → tree is usable.
if [[ -f "$LLVM_PREFIX/lib/libLLVMCore.a" ]]; then
    log_ok "LLVM 15 already present at $LLVM_PREFIX — skipping build"
else
    log_warn "LLVM 15 not found. Building from source — this will take ~30 minutes."
    log_warn "Do NOT interrupt once cmake --build starts; a partial build cannot be resumed."

    if [[ ! -d "$LLVM_SRC_DIR" ]]; then
        log_info "Cloning llvm-project $LLVM_VERSION_TAG"
        git clone \
            --branch "$LLVM_VERSION_TAG" \
            --depth 1 \
            https://github.com/llvm/llvm-project.git \
            "$LLVM_SRC_DIR"
    else
        log_info "llvm-project source already present at $LLVM_SRC_DIR — reusing"
    fi

    _llvm_build_dir="$LLVM_SRC_DIR/build"
    mkdir -p "$_llvm_build_dir"

    log_info "cmake configure"
    cmake -S "$LLVM_SRC_DIR/llvm" -B "$_llvm_build_dir" \
        -DLLVM_ENABLE_PROJECTS="" \
        -DLLVM_TARGETS_TO_BUILD="X86;AArch64" \
        -DLLVM_BUILD_TOOLS=OFF \
        -DLLVM_BUILD_EXAMPLES=OFF \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_ENABLE_RTTI=ON \
        -DCMAKE_BUILD_TYPE=Release \
        "-DCMAKE_OSX_ARCHITECTURES=x86_64" \
        "-DCMAKE_INSTALL_PREFIX=$LLVM_PREFIX"

    log_info "cmake build (this takes ~30 min)"
    cmake --build "$_llvm_build_dir"

    log_info "cmake install"
    cmake --install "$_llvm_build_dir"

    [[ -f "$LLVM_PREFIX/lib/libLLVMCore.a" ]] \
        || die "LLVM install finished but sentinel $LLVM_PREFIX/lib/libLLVMCore.a not found."
    log_ok "LLVM 15 installed at $LLVM_PREFIX"
fi

# ---------------------------------------------------------------------------
# Step 5 — 3Shain Wine toolchain tarball
# ---------------------------------------------------------------------------

log_step "Step 5: Wine toolchain at $WINE_TOOLCHAIN"

if [[ -x "$WINE_TOOLCHAIN/bin/winebuild" ]]; then
    log_ok "Wine toolchain present at $WINE_TOOLCHAIN — skipping download"
else
    _wine_tarball="$DXMT_SRC/toolchains/wine.tar.gz"
    _tc_parent="$DXMT_SRC/toolchains"
    mkdir -p "$_tc_parent"

    if [[ ! -f "$_wine_tarball" ]]; then
        log_info "Downloading Wine toolchain from $WINE_TARBALL_URL"
        curl -fL -o "$_wine_tarball" "$WINE_TARBALL_URL"
        log_ok "Download complete"
    else
        log_info "Tarball already at $_wine_tarball — reusing"
    fi

    log_info "Extracting Wine toolchain"
    tar -xzf "$_wine_tarball" -C "$_tc_parent"

    # The tarball may extract to a versioned directory (e.g. wine-8.16-3shain).
    # Normalise it to the expected name.
    _extracted=$(find "$_tc_parent" -mindepth 1 -maxdepth 1 -type d -name 'wine-*' | head -n1)
    if [[ -n "$_extracted" && "$_extracted" != "$WINE_TOOLCHAIN" ]]; then
        mv "$_extracted" "$WINE_TOOLCHAIN"
        log_ok "Renamed $(basename "$_extracted") -> wine"
    fi

    [[ -x "$WINE_TOOLCHAIN/bin/winebuild" ]] \
        || die "Wine toolchain extracted but winebuild not found at $WINE_TOOLCHAIN/bin/winebuild."
    log_ok "Wine toolchain ready at $WINE_TOOLCHAIN"
fi

# ---------------------------------------------------------------------------
# Step 6 — Xcode Metal toolchain
# ---------------------------------------------------------------------------

log_step "Step 6: Xcode Metal toolchain"

# The download command is idempotent but exits non-zero if already installed;
# suppress that with || true. It is also noisy about being re-installed.
xcodebuild -downloadComponent MetalToolchain 2>/dev/null || true

# Detect the Metal SDK lib directory as a sanity check.
_sdk_path=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)
if [[ -n "$_sdk_path" ]] && ls "$_sdk_path/usr/lib/metal" >/dev/null 2>&1; then
    log_ok "Metal toolchain present at $_sdk_path/usr/lib/metal"
else
    log_warn "Metal toolchain not detected at \${SDK}/usr/lib/metal."
    log_warn "Run 'xcodebuild -downloadComponent MetalToolchain' manually if the build fails."
fi

# ---------------------------------------------------------------------------
# Step 7 — Build DXMT
# ---------------------------------------------------------------------------

log_step "Step 7: Building DXMT from $DXMT_SRC"

cd "$DXMT_SRC"

# Meson refuses absolute include_directories() pointing inside the source
# tree. DXMT's own src/airconv/darwin/meson.build takes advantage of that:
# if native_llvm_path starts with "/" it calls include_directories()
# directly, otherwise it prepends "../../.." first.  CI passes relative
# paths ("toolchains/llvm") so only the relative form works.
llvm_rel=$(python3 -c \
    "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" \
    "$LLVM_PREFIX" "$DXMT_SRC")
wine_rel=$(python3 -c \
    "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" \
    "$WINE_TOOLCHAIN" "$DXMT_SRC")

# -- 64-bit build --
if [[ ! -d "$DXMT_SRC/build" ]]; then
    log_info "meson setup build (64-bit)"
    arch -arm64 "$MESON" setup \
        --cross-file build-win64.txt \
        -Dnative_llvm_path="$llvm_rel" \
        -Dwine_install_path="$wine_rel" \
        build --buildtype release
fi
log_info "meson compile build (64-bit)"
arch -arm64 "$MESON" compile -C "$DXMT_SRC/build"

# -- 32-bit build --
if [[ ! -d "$DXMT_SRC/build32" ]]; then
    log_info "meson setup build32 (32-bit)"
    arch -arm64 "$MESON" setup \
        --cross-file build-win32.txt \
        -Dwine_install_path="$wine_rel" \
        build32 --buildtype release
fi
log_info "meson compile build32 (32-bit)"
arch -arm64 "$MESON" compile -C "$DXMT_SRC/build32"

# ---------------------------------------------------------------------------
# Step 8 — Stage artefacts into Wine bundle + prefix
# ---------------------------------------------------------------------------

log_step "Step 8: Staging built artefacts into Wine + prefix"

install_file() {
    local src=$1 dst=$2
    [[ -f "$src" ]] || die "Missing build output: $src"
    cp "$src" "$dst"
    log_ok "$(basename "$src") -> $dst"
}

install_file "$DXMT_SRC/build/src/winemetal/unix/winemetal.so" \
             "$WINE_LIB_UNIX/winemetal.so"

# Walk the build tree and copy each DXMT DLL regardless of subdirectory depth.
find "$DXMT_SRC/build" -name "*.dll" -print0 | while IFS= read -r -d '' f; do
    name=$(basename "$f")
    case "$name" in
        d3d11.dll|d3d10core.dll|dxgi.dll|winemetal.dll)
            install_file "$f" "$WINE_LIB_WIN64/$name"
            ;;
    esac
done

find "$DXMT_SRC/build32" -name "*.dll" -print0 2>/dev/null | while IFS= read -r -d '' f; do
    name=$(basename "$f")
    case "$name" in
        d3d11.dll|d3d10core.dll|dxgi.dll|winemetal.dll)
            install_file "$f" "$WINE_LIB_WIN32/$name"
            ;;
    esac
done

# The prefix's system32/syswow64 also need winemetal.dll.
cp "$WINE_LIB_WIN64/winemetal.dll" "$PREFIX_SYS32/winemetal.dll" 2>/dev/null || true
cp "$WINE_LIB_WIN32/winemetal.dll" "$PREFIX_SYSWOW64/winemetal.dll" 2>/dev/null || true

log_ok "DXMT fork build staged"
log_info "Next: scripts/experimental/run-with-dxmt-debug.sh (DXMT_LOG_LEVEL=debug)"
