# Building for D3D11 games (v0.6)

`bash install.sh` gets you the Steam UI. Running D3D11 titles
additionally needs:

1. **A DXMT fork build** that fixes the two Wine 11 bugs documented
   in [`docs/dxmt-diagnosis.md`](dxmt-diagnosis.md) Phase D
   (struct ABI drift + `OnMainThread` re-entrance).
2. **A Wine 11 rebuild with `-fvisibility=default`** so the macdrv
   public symbols DXMT needs are actually visible via `dlsym`.

Both are one-off setups. Once done, re-running `bash install.sh`
will keep the rest of the stack up to date.

Budget ~1 hour on first run (LLVM 15 x86_64 self-build + Wine
compile). On a rebuild: minutes.

---

## Step 1 — Prerequisites

```bash
# Tool chain for the DXMT + Wine builds.
brew install meson ninja bison flex cmake gettext mingw-w64 wget
xcodebuild -downloadComponent MetalToolchain    # once
# DXMT's meson.build still requires meson <1.11:
/opt/homebrew/bin/python3 -m pip install --user 'meson==1.10.1'
```

Confirm `/opt/homebrew/bin/meson --version` prints `1.10.x`. If
Homebrew installed 1.11+ too, the fork build script picks up the pip
install via the `MESON` environment variable.

---

## Step 2 — Fork the DXMT repo locally

```bash
# Clone the v0.6 fork alongside steam-on-m1-wine.
# $HOME/dev/dxmt is the default that scripts/experimental/07 expects;
# override with DXMT_SRC=<path> if you prefer elsewhere.
git clone --branch debug/present-path-tracing \
    https://github.com/notpop/dxmt.git ~/dev/dxmt
cd ~/dev/dxmt
git submodule update --init --recursive
```

---

## Step 3 — Build the x86_64 LLVM 15 that DXMT's shader compiler
needs

DXMT compiles its airconv shader translator against LLVM 15 with
x86_64 as the target architecture. Homebrew's `llvm@15` is arm64-only
and cannot link DXMT. Follow
[`docs/DEVELOPMENT.md` of the fork](https://github.com/notpop/dxmt/blob/debug/present-path-tracing/docs/DEVELOPMENT.md)
for the cmake recipe. The output must land at
`~/dev/dxmt/toolchains/llvm/` (override with `LLVM_PREFIX`).

This step takes ~30 min on an M1 and only has to be done once per
LLVM version bump.

---

## Step 4 — Drop in the 3Shain Wine build tree

DXMT links against Wine's own `libwinecrt0.a`, `libntdll.a`, and
`libdbghelp.a`. The upstream Wine 11.0 source ships them, but the
simplest path is to grab the 3Shain pre-built tarball that DXMT's CI
uses.

```bash
cd ~/dev/dxmt
mkdir -p toolchains
curl -L -o toolchains/wine.tar.gz \
    https://github.com/3Shain/wine/releases/download/v8.16-3shain/wine.tar.gz
tar -xzf toolchains/wine.tar.gz -C toolchains/
mv toolchains/wine-* toolchains/wine
```

---

## Step 5 — Build DXMT + stage into Wine

```bash
cd <this repo>
bash scripts/experimental/07-build-dxmt-from-fork.sh
```

The script runs the 64-bit and 32-bit meson builds and copies:

- `winemetal.so` → `/Applications/Wine Stable.app/Contents/Resources/wine/lib/wine/x86_64-unix/`
- `d3d11.dll`, `d3d10core.dll`, `dxgi.dll`, `winemetal.dll` →
  `x86_64-windows/` and `i386-windows/` of the same Wine tree, plus
  the prefix's `system32` / `syswow64` for `winemetal.dll`.

---

## Step 6 — Rebuild Wine 11 with `-fvisibility=default`

Wine's `configure.ac` appends `-fvisibility=hidden` to `EXTRACFLAGS`
unconditionally. We need the macdrv public functions to be visible
via `dlsym`.

```bash
# Grab Wine 11.0 source.
git clone --branch wine-11.0 https://gitlab.winehq.org/wine/wine.git \
    ~/dev/wine-build/wine
cd ~/dev/wine-build/wine
./configure --enable-win64 --disable-tests \
    CFLAGS='-fvisibility=default -O2 -Wno-error' \
    CXXFLAGS='-fvisibility=default -O2 -Wno-error'
make -j"$(sysctl -n hw.ncpu)"
```

Expect ~30 min on an M1.

After the build finishes, replace only the one shared object that
matters, keeping the rest of the Gcenx `wine-stable` cask intact:

```bash
WINE_UNIX=/Applications/Wine\ Stable.app/Contents/Resources/wine/lib/wine/x86_64-unix
sudo cp "$WINE_UNIX/winemac.so" "$WINE_UNIX/winemac.so.gcenx-backup"
sudo cp ~/dev/wine-build/wine/dlls/winemac.drv/winemac.so "$WINE_UNIX/winemac.so"
```

Sanity check — the rebuilt `winemac.so` should export ~200 text
symbols where the Gcenx cask exported zero:

```bash
nm -g "$WINE_UNIX/winemac.so" | awk '$2=="T"' | wc -l   # expect ~200
```

---

## Step 7 — Launch & verify

```bash
bash scripts/experimental/run-with-dxmt-debug.sh
```

Wait for Steam UI to come up, then launch any Unity D3D11 title from
your library.

Tail the debug trace:

```bash
tail -f /tmp/dxmt-logs/*.log \
    /var/folders/*/*/T/steam-on-m1-wine.log
```

A successful run emits, on every swap-chain create:

```
[dxmt/winemetal] CreateMetalViewFromHWND: done hwnd=0x...
  cocoa_window=0x<non-zero> content_view=0x<non-zero>
  view=0x<non-zero> layer=0x<non-zero>
```

followed by thousands of:

```
debug: DXMT trace Present1: sync=... hr=0x0
```

If `view` or `layer` is zero, the Wine rebuild didn't take — re-check
Step 6's `nm -g` count.

---

## Rolling back

The Gcenx `winemac.so` was backed up in Step 6 as
`winemac.so.gcenx-backup`. To revert:

```bash
WINE_UNIX=/Applications/Wine\ Stable.app/Contents/Resources/wine/lib/wine/x86_64-unix
sudo mv "$WINE_UNIX/winemac.so.gcenx-backup" "$WINE_UNIX/winemac.so"
```

DXMT itself can be rolled back to the upstream v0.74 stage with:

```bash
bash scripts/04-install-dxmt.sh      # re-stages v0.74 over the fork
```

---

## Future: prebuilt distribution

Both the DXMT fork binaries and the patched `winemac.so` are LGPL/MIT
compatible and small enough to ship as a GitHub Release asset on this
repo. A future `scripts/08-fetch-prebuilt.sh` could collapse Steps
3–6 into a single download, turning the D3D11 path into one more
`bash install.sh --full` command. Not yet implemented.
