# Architecture

`steam-on-m1-wine` is a chain of shell scripts that assemble **four**
pieces of software into a working Steam + D3D11 stack on Apple Silicon:

1. **Wine 11** (Gcenx Homebrew Cask) -- the Windows API host
2. **Wine visibility patch** -- `winemac.so` rebuilt with
   `-fvisibility=default` so `macdrv_*` symbols are `dlsym`-reachable
3. **DXMT fork** (`notpop/dxmt@debug/present-path-tracing`) -- Metal
   bridge with a rewritten `_CreateMetalViewFromHWND`
4. **steamwebhelper wrapper** -- thin PE shim that forces CEF flags and
   redirects to `steamwebhelper_real.exe`

At runtime, all four are unified inside a **Wine virtual desktop**
(`explorer.exe /desktop=steam-on-m1-wine,WxH`) so CEF and game windows
share a single `CAMetalLayer` surface hierarchy.

This document explains why each layer is required and where it
intercepts the stack. For low-level diagnosis traces see
`docs/dxmt-diagnosis.md`.

## The failure chain without these fixes

A stock Homebrew `wine-stable` prefix with Steam installed exhibits
a three-layer bug cascade on Apple Silicon / Wine 11:

```
Steam launches
    ├── steamwebhelper.exe starts Chromium 126 (CEF) .......... OK
    ├── CEF requests a D3D11 swap-chain ........................ FAIL (1)
    │       Wine macdrv symbols hidden by -fvisibility=hidden
    │       => DXMT cannot dlsym macdrv_view_create_metal_view
    │          => swap-chain creation returns E_FAIL
    │             => CEF UI renders as a permanent black window
    │
    ├── DXMT calls macdrv_view_create_metal_view ............... FAIL (2)
    │       Wine 11 struct macdrv_win_data ABI drift:
    │       expected field offset for the CALayer* is wrong.
    │       GDI present path leaves the pointer NULL at the
    │       moment DXMT tries to attach a Metal view to it.
    │
    └── macdrv_view_create_metal_view / OnMainThread ........... FAIL (3)
            macdrv internals dispatch via OnMainThread().
            If the caller already holds that trampoline the
            second dispatch deadlocks. DXMT's call-site in
            the swap-chain creation path hits this re-entrancy.
```

Each failure is independent; fixing only one still breaks the stack.
Full reproduction and fix evidence is in `docs/dxmt-diagnosis.md`
Phase D.

Additionally, Chromium's network utility process inherits Wine's
broken winsock SSL path. `--enable-features=NetworkServiceInProcess`
is not honored by CEF 126, so the only working fix is `--single-process`
(which also satisfies the GPU process constraint).

## Layered diagram

```
macOS Tahoe 26 (Apple Silicon, arm64 + Rosetta 2)
└── Wine 11.0 (x86_64, Gcenx Homebrew cask)
    └── winemac.so  (self-built, -fvisibility=default, swapped in)
        └── explorer.exe /desktop=steam-on-m1-wine,WxH
            ├── Steam.exe
            │   └── steamwebhelper.exe  (our wrapper)
            │       └── steamwebhelper_real.exe
            │                --disable-gpu --single-process
            │           └── Chromium 126 (CEF)
            └── <Game>.exe  (Unity / Unreal / D3D11)
                └── DXMT (fork v0.6)
                    ├── d3d11.dll / d3d10core.dll / dxgi.dll
                    └── winemetal.so  <-- Metal-side bridge
                        └── Metal / CAMetalLayer
```

## What each script does

### `00-prereqs.sh` -- environment check

Verifies Rosetta 2 is installed, Homebrew is present, and Xcode
Command Line Tools are available. Aborts with a clear message if any
are missing; subsequent scripts assume this baseline.

### `01-install-wine.sh` -- Wine + Gatekeeper

Installs `wine-stable` via the Gcenx Homebrew Cask, then removes
`com.apple.quarantine` from the bundle. Without that strip, macOS
Tahoe's unsigned-binary policy SIGKILLs `wine` on first exec.

### `02-setup-prefix.sh` -- prefix and fonts

Creates the Wine prefix (default `~/.wine-steam`), then copies Japanese
system fonts from `/System/Library/` and `/System/Library/AssetsV2/`
so Steam UI can render Japanese glyphs. The fonts belong to the user
already; this is a user-to-user copy.

### `03-install-steam.sh` -- Steam installer

Downloads `SteamSetup.exe` from the Valve CDN, verifies it is a valid
PE executable, runs it silently (`/S`), and asserts `Steam.exe` ends up
in the prefix. No Steam code is committed to this repository.

### `04-install-dxmt.sh` -- DXMT v0.74 fallback stage

Places the upstream DXMT v0.74 release into the Wine prefix so that
Steam's UI layer comes up even before the fork is built. The fork
(script `07`) overwrites these files. This stage ensures the setup
pipeline reaches a testable state early.

| File                | Destination                                                      |
| ------------------- | ----------------------------------------------------------------- |
| `winemetal.so`      | `<wine>/lib/wine/x86_64-unix/winemetal.so`                        |
| `winemetal.dll`     | `<wine>/lib/wine/x86_64-windows/` **and** `<prefix>/system32/`    |
| `d3d11.dll`         | `<wine>/lib/wine/x86_64-windows/`                                 |
| `dxgi.dll`          | `<wine>/lib/wine/x86_64-windows/`                                 |
| `d3d10core.dll`     | `<wine>/lib/wine/x86_64-windows/`                                 |

### `05-fix-ssl.sh` -- CA bundle and corefonts

Places the system CA bundle at `C:\windows\cacert.pem` and installs
Microsoft core fonts. Without corefonts some CEF error pages refuse to
lay out, which presents as another blank screen.

### `06-install-wrapper.sh` -- steamwebhelper wrapper

Builds `wrapper/steamwebhelper.exe` from C using Homebrew's
`x86_64-w64-mingw32-gcc`, renames Valve's binary to
`steamwebhelper_real.exe`, and drops the wrapper in its place. The
wrapper prepends `--disable-gpu --single-process` to every invocation:

- `--disable-gpu` prevents CEF from creating its own D3D11 context
  outside the DXMT-managed path, avoiding the black-window regression
  seen with Chromium 126 on out-of-process GPU mode.
- `--single-process` collapses Chromium's network utility process into
  the main process, side-stepping the Wine winsock SSL bug.
  `--enable-features=NetworkServiceInProcess` was tested and confirmed
  not honored by CEF 126.

### `07-build-dxmt-fork.sh` -- DXMT fork build (v0.6, new)

Clones `github.com/notpop/dxmt@debug/present-path-tracing`, downloads
the 3Shain Wine toolchain, and builds DXMT with LLVM 15 targeting
x86_64. The resulting `winemetal.so` and DLLs overwrite the v0.74
fallback staged by script `04`. Build details and LLVM version
requirements are documented in `docs/building-for-games.md`.

### `08-patch-wine-visibility.sh` -- Wine visibility patch (v0.6, new)

Rebuilds Wine 11's macOS driver (`dlls/winemac.drv`) with
`-fvisibility=default` so that `macdrv_*` C symbols are exported and
`dlsym`-reachable at runtime. Only `winemac.so` is swapped; the rest
of the Wine bundle is left untouched. The original Gcenx-provided
`winemac.so` is retained as a `.gcenx-backup` alongside it so a Cask
upgrade can restore the old file without rerunning the full script.

Without this patch DXMT cannot locate `macdrv_view_create_metal_view`
at link time and swap-chain creation fails immediately (failure 1 in
the cascade above).

### `09-install-macos-app.sh` -- macOS app bundle

Generates `~/Applications/Steam on M1 Wine.app`. The app is a thin
shell-script bundle that calls `launch-steam.sh`; it carries a custom
icon and a proper `CFBundleIdentifier` so macOS Mission Control treats
it as a first-class application.

### `10-add-to-dock.sh` -- Dock registration (opt-in)

Adds the app bundle to the user's Dock via `defaults write`. This
script is never called automatically; it is an explicit opt-in step.

### `launch-steam.sh` -- runtime launcher

Orchestrates a clean, reproducible Steam session:

1. Kill any running Steam / Wine session.
2. Delete `SingletonLock` from the Steam userdata directory (a common
   Wine-crash leftover that degrades the next launch to `--silent`).
3. Verify wrapper integrity (confirms `steamwebhelper.exe` is ours,
   not a Valve update that silently overwrote it).
4. Scrub `STEAM_COMPAT_FLAGS` for `DISABLEDXMAXIMIZEDWINDOWEDMODE`,
   which conflicts with the virtual desktop geometry.
5. Set Wine registry key
   `HKCU\Software\Wine\Mac Driver\AllowImmovableWindows` to `n` so
   the virtual desktop window cannot be pinned behind other macOS
   windows.
6. Launch Steam inside `explorer.exe /desktop=steam-on-m1-wine,WxH`
   where `WxH` is the current display resolution, keeping all Wine
   windows contained in one managed surface.

## Why we maintain a fork

Upstream DXMT v0.74 is compatible with older Wine but breaks on
Wine 11 for two reasons:

- **ABI drift**: `struct macdrv_win_data` field layout changed between
  the Wine version DXMT was developed against and Wine 11. The CALayer
  pointer DXMT reads is at the wrong offset, and the GDI present path
  leaves it NULL at swap-chain creation time anyway (failure 2).
- **OnMainThread re-entrancy**: `macdrv_view_create_metal_view`
  internally dispatches via `OnMainThread()`. DXMT's call-site wraps
  the call in its own `OnMainThread()` trampoline, causing a deadlock
  on the second nested dispatch (failure 3).

The fork (`notpop/dxmt@debug/present-path-tracing`) addresses both by
rewriting `_CreateMetalViewFromHWND` (~150 line diff). A PR to the
upstream `3Shain/dxmt` is planned; a draft issue is at
`docs/upstream-issue-draft.md`.
