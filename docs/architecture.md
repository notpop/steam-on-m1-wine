# Architecture

`steam-on-m1-wine` is a small chain of shell scripts that layer three
pieces of software on top of Homebrew-packaged Wine:

1. **Wine 11 (stable)** — the Windows API implementation
2. **DXMT** — a Metal-based Direct3D 11 / 10 translation layer
3. A **wrapper** for `steamwebhelper.exe` that forces CEF's GPU
   process to run in-process

This document explains why each layer is there and what it fixes.

## The failure chain without these fixes

A stock Homebrew `wine-stable` prefix with Steam installed exhibits
this cascade on Apple Silicon:

```
Steam launches
    ├── Initial bootstrapper updates self-package ................ OK
    ├── steam.exe starts steamwebhelper.exe  ..................... OK
    ├── CEF (Chromium 126) creates a D3D11 swapchain ............. FAIL
    │       └── ANGLE falls back to wined3d's OpenGL path
    │           └── wined3d can't satisfy "GLES 3.0 >= required(2.0)"
    │               └── UI renders as a black window
    └── Chromium tries HTTPS to steam CDNs ........................ FAIL
            └── ssl_client_socket_impl handshake -100 / -107
                └── downstream of the GPU / sandboxing above
```

The UI never paints. Even if the user could click Login they couldn't,
because the Chromium view is never drawn.

## What each script corrects

### `01-install-wine.sh` — Wine + winetricks + Gatekeeper

Installs `wine-stable` via Homebrew Cask, then removes
`com.apple.quarantine` from the bundle. Without that strip, macOS
Tahoe's unsigned-binary policy SIGKILLs `wine` on first exec.

### `02-setup-prefix.sh` — prefix and fonts

Creates the Wine prefix (default `~/.wine-steam`), then copies Japanese
system fonts from `/System/Library/` and `/System/Library/AssetsV2/`
so Steam UI can render Japanese glyphs. The fonts belong to the user
already; this is a user-to-user copy.

### `03-install-steam.sh` — Steam installer

Downloads `SteamSetup.exe` from the Valve CDN, verifies it is a valid
PE executable, runs it silently (`/S`), and asserts `Steam.exe` ends up
in the prefix. No Steam code is committed to this repository.

### `04-install-dxmt.sh` — D3D11 → Metal

Places DXMT's builtin build files where Wine expects them:

| File                | Destination                                                      |
| ------------------- | ----------------------------------------------------------------- |
| `winemetal.so`      | `<wine>/lib/wine/x86_64-unix/winemetal.so`                        |
| `winemetal.dll`     | `<wine>/lib/wine/x86_64-windows/` **and** `<prefix>/system32/`    |
| `d3d11.dll`         | `<wine>/lib/wine/x86_64-windows/`                                 |
| `dxgi.dll`          | `<wine>/lib/wine/x86_64-windows/`                                 |
| `d3d10core.dll`     | `<wine>/lib/wine/x86_64-windows/`                                 |

Writing into the Wine bundle means a future Homebrew Cask upgrade will
clobber these files. That is intentional: rerun `04-install-dxmt.sh`
after every Wine upgrade.

### `05-fix-ssl.sh` — prefix CA bundle + corefonts

Not a direct TLS fix (Chromium uses its own BoringSSL), but puts the
system's CA bundle in `C:\windows\cacert.pem` and installs Microsoft
core fonts via `winetricks`. Without corefonts some Chromium error
pages refuse to lay out, which reads as another blank screen.

### `06-install-wrapper.sh` — steamwebhelper wrapper

Builds `wrapper/steamwebhelper.exe` from C via Homebrew's
`x86_64-w64-mingw32-gcc`, renames Valve's binary to
`steamwebhelper_real.exe`, and drops the wrapper in its place. The
wrapper prepends `--in-process-gpu` to every invocation so Chromium
runs its GPU code inside the main browser process. DXMT does not
support CEF's default out-of-process swapchain
(see [DXMT Issue #141](https://github.com/3Shain/dxmt/issues/141)).

### `launch-steam.sh` — runtime

Kills previous sessions, purges Chromium's SingletonLock (a classic
Wine-crash leftover that reduces the next launch to `--silent`),
exports `WINEDLLOVERRIDES="dxgi,d3d11,d3d10core=n,b"`, and starts
Steam with the CEF flag set that has been validated on this hardware.

## Layered diagram

```
 ┌──────────────────────────────────────────────────────────┐
 │ Steam.exe (Windows)                                      │
 │   └── steamwebhelper.exe  ← our wrapper                  │
 │       └── steamwebhelper_real.exe --in-process-gpu ...   │
 │           └── Chromium 126 renderer                      │
 │               └── D3D11 calls                            │
 └─────────────────────────┬────────────────────────────────┘
                           │
                   ┌───────▼───────┐
                   │  DXMT (PE+so) │   ← native DLLs in system32
                   │  d3d11/dxgi   │     winemetal.so in wine/
                   └───────┬───────┘
                           │
                   ┌───────▼───────┐
                   │ Wine 11.0     │   ← /Applications/Wine Stable.app
                   │ (x86_64)      │     under Rosetta 2
                   └───────┬───────┘
                           │
                   ┌───────▼───────┐
                   │ macOS Tahoe   │   ← M1, arm64 + Rosetta 2
                   └───────────────┘
```

## Why this project pins DXMT v0.74

DXMT only publishes "builtin" release archives. The Wiki's "Installation
guide for geeks" says Wine ≥ 8 with `winemac.drv` symbols exposed is
sufficient. Gcenx's Homebrew `wine-stable` 11.0 is such a build, so
v0.74 tarball drops in cleanly. Future DXMT tags are likely to work
similarly, but bumping `DXMT_TAG` in `scripts/04-install-dxmt.sh`
should be a conscious, tested change — update the pinned SHA256 at
the same time.
