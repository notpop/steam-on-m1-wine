#!/usr/bin/env bash
#
# 07-build-dxmt-from-fork.sh — Build DXMT from a local fork checkout
# and stage the resulting DLLs + .so into the same Wine install path
# that `scripts/04-install-dxmt.sh` and
# `scripts/experimental/04b-install-dxmt-nightly.sh` write to.
#
# Use case
# --------
# You have local source changes in a fork of DXMT (e.g. the
# `debug/present-path-tracing` branch on github.com/notpop/dxmt).
# You want to test them on this Mac without touching upstream.
#
# Prerequisites
# -------------
# - DXMT checkout at $DXMT_SRC (default: ~/dev/dxmt)
# - Homebrew-installed meson, ninja, mingw-w64, bison, flex, cmake,
#   gettext, wget or curl
# - Homebrew's `llvm@15` is *not* sufficient for the cross x86_64
#   link (it's arm64-only); you must have an x86_64 LLVM at
#   $DXMT_SRC/toolchains/llvm (built via the CMake recipe documented
#   in docs/DEVELOPMENT.md of the fork)
# - A Wine install tree at $DXMT_SRC/toolchains/wine that contains
#   lib/wine/<arch>-windows/libwinecrt0.a, libntdll.a, libdbghelp.a
#   and bin/winebuild. The 3Shain v8.16-3shain wine.tar.gz is known
#   to work; 04b-install-dxmt-nightly.sh's download logic also helps
#   obtain it
# - Xcode's Metal toolchain installed
#   (`xcodebuild -downloadComponent MetalToolchain` once)
#
# What this script does NOT do
# ----------------------------
# Any of the above preparation steps. Those require a developer
# judgement (where to put the LLVM tree, which Wine tarball to use)
# and take real time; automating them inside this script would paper
# over choices that belong to the operator.

# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
require_wine_installed
require_prefix_initialised

DXMT_SRC="${DXMT_SRC:-$HOME/dev/dxmt}"
LLVM_PREFIX="${LLVM_PREFIX:-$DXMT_SRC/toolchains/llvm}"
WINE_TOOLCHAIN="${WINE_TOOLCHAIN:-$DXMT_SRC/toolchains/wine}"

WINE_LIB_UNIX="$WINE_APP/Contents/Resources/wine/lib/wine/x86_64-unix"
WINE_LIB_WIN64="$WINE_APP/Contents/Resources/wine/lib/wine/x86_64-windows"
WINE_LIB_WIN32="$WINE_APP/Contents/Resources/wine/lib/wine/i386-windows"
PREFIX_SYS32="$WINEPREFIX/drive_c/windows/system32"
PREFIX_SYSWOW64="$WINEPREFIX/drive_c/windows/syswow64"

log_step "Building DXMT from $DXMT_SRC"

[[ -d "$DXMT_SRC" ]] \
    || die "DXMT checkout not found at $DXMT_SRC. Clone github.com/notpop/dxmt there (or set DXMT_SRC)."
[[ -d "$LLVM_PREFIX/lib" ]] \
    || die "Expected x86_64 LLVM at $LLVM_PREFIX. Build it once via DXMT's docs/DEVELOPMENT.md instructions."
[[ -x "$WINE_TOOLCHAIN/bin/winebuild" ]] \
    || die "Wine toolchain missing or incomplete at $WINE_TOOLCHAIN."

cd "$DXMT_SRC"

# Init git submodules (idempotent; cheap if already done).
log_info "git submodule update"
git submodule update --init --recursive >/dev/null

# -- 64-bit build --
if [[ ! -d build ]]; then
    log_info "meson setup build (64-bit)"
    arch -arm64 /opt/homebrew/bin/meson setup \
        --cross-file build-win64.txt \
        -Dnative_llvm_path="$LLVM_PREFIX" \
        -Dwine_install_path="$WINE_TOOLCHAIN" \
        build --buildtype release
fi
log_info "meson compile build (64-bit)"
arch -arm64 /opt/homebrew/bin/meson compile -C build

# -- 32-bit build --
if [[ ! -d build32 ]]; then
    log_info "meson setup build32 (32-bit)"
    arch -arm64 /opt/homebrew/bin/meson setup \
        --cross-file build-win32.txt \
        -Dwine_install_path="$WINE_TOOLCHAIN" \
        build32 --buildtype release
fi
log_info "meson compile build32 (32-bit)"
arch -arm64 /opt/homebrew/bin/meson compile -C build32

# -- Stage the outputs over the Wine bundle + prefix --
install_file() {
    local src=$1 dst=$2
    [[ -f "$src" ]] || die "Missing build output: $src"
    cp "$src" "$dst"
    log_ok "$(basename "$src") -> $dst"
}

log_step "Staging built artefacts into Wine + prefix"

install_file "$DXMT_SRC/build/src/winemetal/unix/winemetal.so" \
             "$WINE_LIB_UNIX/winemetal.so"

# Walk the build tree and copy each DXMT DLL regardless of path.
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
