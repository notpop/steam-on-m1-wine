#!/usr/bin/env bash
#
# package-prebuilt.sh — Bundle the artefacts produced by scripts 07 and 08
# into a versioned tarball suitable for a GitHub Release, so other users can
# skip the ~1.5 hour source build.
#
# Collects:
#   x86_64-unix/winemetal.so          (DXMT fork, 64-bit unix side)
#   x86_64-unix/winemac.so            (Wine 11 rebuilt with -fvisibility=default)
#   x86_64-windows/{d3d11,d3d10core,dxgi,winemetal}.dll
#   i386-windows/{d3d11,d3d10core,dxgi,winemetal}.dll
#
# Also writes BUILD-INFO.md (exact source commits, local diffs, toolchain
# versions), LICENSES/, and SHA256SUMS. Redistributing Wine (LGPL) and DXMT
# binaries requires pointing at the corresponding source; BUILD-INFO.md and
# the patches/ directory do that.
#
# Usage:  bash scripts/package-prebuilt.sh [VERSION]
#         VERSION defaults to "macos26-1".

set -euo pipefail

VERSION="${1:-macos26-1}"
DXMT_SRC="${DXMT_SRC:-$HOME/dev/dxmt}"
WINE_BUILD_SRC="${WINE_BUILD_SRC:-$HOME/dev/wine-build/wine}"
ZSTD_SRC="${ZSTD_SRC:-$HOME/Downloads/zstd-1.5.7}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/dist}"

NAME="steam-on-m1-wine-prebuilt-${VERSION}"
STAGE="$OUT_DIR/$NAME"

ok()   { printf '\033[32m[OK]\033[0m %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# -- Locate inputs ------------------------------------------------------------

[[ -d "$DXMT_SRC/build" ]]   || die "No 64-bit DXMT build at $DXMT_SRC/build (run install.sh first)"
[[ -d "$DXMT_SRC/build32" ]] || die "No 32-bit DXMT build at $DXMT_SRC/build32"
WINEMAC="$WINE_BUILD_SRC/build/dlls/winemac.drv/winemac.so"
[[ -f "$WINEMAC" ]] || die "No rebuilt winemac.so at $WINEMAC (run script 08 first)"
WINEMETAL_SO="$DXMT_SRC/build/src/winemetal/unix/winemetal.so"
[[ -f "$WINEMETAL_SO" ]] || die "Missing $WINEMETAL_SO"

rm -rf "$STAGE"
mkdir -p "$STAGE/x86_64-unix" "$STAGE/x86_64-windows" "$STAGE/i386-windows" \
         "$STAGE/patches" "$STAGE/LICENSES"

# -- Copy artefacts -----------------------------------------------------------

cp "$WINEMETAL_SO" "$STAGE/x86_64-unix/winemetal.so"
cp "$WINEMAC"      "$STAGE/x86_64-unix/winemac.so"

copy_dlls() {
    local build_dir=$1 dest=$2 name found
    for name in d3d11.dll d3d10core.dll dxgi.dll winemetal.dll; do
        found=$(find "$build_dir" -name "$name" -type f | head -n1)
        [[ -n "$found" ]] || die "Missing $name under $build_dir"
        cp "$found" "$dest/$name"
    done
}
copy_dlls "$DXMT_SRC/build"   "$STAGE/x86_64-windows"
copy_dlls "$DXMT_SRC/build32" "$STAGE/i386-windows"
ok "Copied 10 artefacts"

# -- Sanity checks ------------------------------------------------------------

for so in "$STAGE"/x86_64-unix/*.so; do
    arch=$(lipo -archs "$so" 2>/dev/null || echo unknown)
    [[ "$arch" == "x86_64" ]] || die "$(basename "$so") is '$arch', expected x86_64"

    # A binary that links against Homebrew paths will not run on machines
    # without the same Homebrew libs. Fail loudly instead of shipping it.
    if otool -L "$so" | tail -n +2 | grep -Eq '/opt/homebrew|/usr/local/'; then
        otool -L "$so"
        die "$(basename "$so") links against a Homebrew/usr/local library (non-portable)"
    fi
done
ok "Unix-side libraries are x86_64 and only link system libraries"

pub=$(nm -g "$STAGE/x86_64-unix/winemac.so" 2>/dev/null | grep -c ' T ' || true)
(( pub >= 100 )) || die "winemac.so has only $pub public symbols (visibility patch missing?)"
ok "winemac.so exports $pub public symbols"

# -- Provenance / license compliance -----------------------------------------

dxmt_remote=$(git -C "$DXMT_SRC" remote get-url upstream 2>/dev/null \
              || git -C "$DXMT_SRC" remote get-url origin)
dxmt_branch=$(git -C "$DXMT_SRC" rev-parse --abbrev-ref HEAD)
dxmt_commit=$(git -C "$DXMT_SRC" rev-parse HEAD)
git -C "$DXMT_SRC" diff > "$STAGE/patches/dxmt-local.diff"

wine_remote=$(git -C "$WINE_BUILD_SRC" remote get-url origin 2>/dev/null || echo "https://gitlab.winehq.org/wine/wine.git")
wine_commit=$(git -C "$WINE_BUILD_SRC" rev-parse HEAD)
git -C "$WINE_BUILD_SRC" diff > "$STAGE/patches/wine-local.diff"

cp "$DXMT_SRC/LICENSE" "$STAGE/LICENSES/DXMT-LICENSE" 2>/dev/null \
    || warn "DXMT LICENSE not found; add it manually"
cp "$WINE_BUILD_SRC/COPYING.LIB" "$STAGE/LICENSES/WINE-COPYING.LIB" 2>/dev/null \
    || warn "Wine COPYING.LIB not found; add it manually"
cp "$WINE_BUILD_SRC/LICENSE" "$STAGE/LICENSES/WINE-LICENSE" 2>/dev/null || true
# If the local zstd workaround was used, zstd code is statically linked in.
if [[ -s "$STAGE/patches/dxmt-local.diff" ]] && grep -q lzstd "$STAGE/patches/dxmt-local.diff"; then
    cp "$ZSTD_SRC/LICENSE" "$STAGE/LICENSES/ZSTD-LICENSE" 2>/dev/null \
        || warn "zstd is statically linked but its LICENSE was not found at $ZSTD_SRC"
fi

cat > "$STAGE/BUILD-INFO.md" <<EOF
# ${NAME}

Prebuilt binaries for [steam-on-m1-wine](https://github.com/notpop/steam-on-m1-wine),
built with the macOS 26 install fixes. Drop-in replacements for the outputs of
\`scripts/07-build-dxmt-fork.sh\` and \`scripts/08-patch-wine-visibility.sh\`.

Target: Gcenx Wine Stable 11.0_1 (\`/Applications/Wine Stable.app\`).

## Sources

| Component | Source | Commit |
|---|---|---|
| DXMT (winemetal.so, *.dll) | ${dxmt_remote} (branch \`${dxmt_branch}\`) | \`${dxmt_commit}\` |
| winemac.so | ${wine_remote} (tag \`wine-11.0\`) | \`${wine_commit}\` |

Local modifications on top of those commits are in \`patches/\`
(an empty file means none).

winemac.so was configured with:
\`--enable-win64 --disable-tests --without-freetype CC='clang -arch x86_64'
CFLAGS='-fvisibility=default -O2 -Wno-error'\` and built as the single
target \`dlls/winemac.drv/winemac.so\`.

## Build environment

- macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(sysctl -n machdep.cpu.brand_string)
- $(x86_64-w64-mingw32-gcc --version | head -n1)
- $(clang --version | head -n1)
- meson $("${MESON:-meson}" --version 2>/dev/null || echo unknown)
- LLVM 15.0.7 (x86_64 static, for DXMT's airconv)
- Built: $(date -u +%Y-%m-%dT%H:%MZ)

## Licenses

Wine is LGPL-2.1-or-later; DXMT's license is included in \`LICENSES/\`.
Source for every binary here is available at the commits above plus the
diffs in \`patches/\`.
EOF

# -- Checksums + tarball ------------------------------------------------------

( cd "$STAGE" && find . -type f ! -name SHA256SUMS -print0 | sort -z \
    | xargs -0 shasum -a 256 > SHA256SUMS )
tar -czf "$OUT_DIR/$NAME.tar.gz" -C "$OUT_DIR" "$NAME"
( cd "$OUT_DIR" && shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )

ok "Bundle: $OUT_DIR/$NAME.tar.gz"
info "SHA256: $(cut -d' ' -f1 "$OUT_DIR/$NAME.tar.gz.sha256")"
info "Contents:"
( cd "$STAGE" && find . -type f | sort | sed 's|^\./|  |' )
