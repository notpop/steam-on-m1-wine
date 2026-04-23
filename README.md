# steam-on-m1-wine

Reproducible, script-driven setup for running the Windows **Steam** client
on an Apple Silicon (M-series) Mac via Homebrew-packaged Wine — no paid
compatibility layer required.

> **Status:** v0.5 — visibility problem fixed, `client_cocoa_view`
> race identified as the next wall. Steam UI is fully functional;
> game rendering is blocked by a Wine 11 `macdrv` lifecycle change
> (the Cocoa view is not yet populated in `struct macdrv_win_data`
> at the point DXMT reads it). Full write-up + reproducible
> evidence in [`docs/dxmt-diagnosis.md`](docs/dxmt-diagnosis.md).
> Drafts of the two upstream reports (DXMT short bug report,
> WineHQ Bugzilla ticket) are in `docs/upstream-issue-draft.md`
> and `docs/wine-bugzilla-draft.md`.
> Tracks the upstream state of Wine, DXMT, and Steam as of April 2026.
> Targets macOS Tahoe 26.x on M1 / M2 / M3 / M4 hardware.

## What works (v0.2)

On the reference machine (M1 MacBook Pro 13" 2020, 16 GB, macOS Tahoe
26.4) `scripts/launch-steam.sh` produces:

- **Steam UI**: fully rendered store, library, and navigation, Japanese
  text via Hiragino Sans GB, authenticated login against Valve's
  servers, cart and wishlist visible.
- **Game launch**: a 32-bit Unity 6000 title (幻獣大農場) spawns, passes
  `D3D11CreateDevice` (sees `Renderer: Apple M1`), completes Unity
  engine initialisation (`[Physics::Module]` and `Input initialized`
  in `Player.log`), and registers a macOS window.

## What is still blocked (v0.3)

- **Game rendering** — the game's `Present()` calls never seem to reach
  the `CAMetalLayer` the `NSWindow` is backed by. The window exists
  at 3840x2160 (Retina raw pixels) but stays transparent / lets the
  desktop wallpaper show through. See `docs/troubleshooting.md`.
- Upstream status as of 2026-04-23: **not fixed in DXMT master HEAD**.
  We tested the most recent CI artifact (commit `43a16e9`, covering
  `40fae03` "present rect for d3dkmt" and `719d247` "defatalize
  IDXGISwapChain1/2/3 stubs"). The symptom shape changed — the game
  process goes from 100% CPU busy-looping on v0.74 to 0% CPU idle
  waiting on master — but the final frame never reaches the screen.
  Full write-up in `docs/dxmt-nightly-experiment.md`.
- Next experiment: fork DXMT, add traces around
  `IDXGISwapChain::Present` → `CAMetalLayer.nextDrawable` →
  `presentDrawable:` and inspect where the macOS Tahoe AppKit
  lifecycle swallows the frame. Tracked separately in the
  `experimental/` scripts and the forthcoming fork branch.

## How it gets there

The working combination, from outer layer to inner:

```
macOS Tahoe 26.4 (arm64)
 └── Rosetta 2 (x86_64 → arm64)
      └── Wine 11.0 stable (Homebrew cask)
           ├── Steam.exe
           │    └── steamwebhelper.exe  (replaced by our C wrapper)
           │         └── steamwebhelper_real.exe --disable-gpu --single-process
           │              → Chromium CPU raster; UI renders
           └── MonsterFarm.exe (Unity 6000, 32-bit)
                └── D3D11 → DXMT → Metal
```

1. **Wine 11.0 stable** (Homebrew cask, `com.apple.quarantine` stripped)
2. **DXMT v0.74** staged into both 64-bit and 32-bit Wine slots
   (`lib/wine/x86_64-windows/` + `lib/wine/i386-windows/` +
   `system32` + `syswow64`). 32-bit is required for Unity games that
   ship as 32-bit Windows binaries.
3. **Self-compiled `steamwebhelper` wrapper** that renames the Valve
   binary to `steamwebhelper_real.exe` and prepends
   `--disable-gpu --single-process` to every invocation. This
   collapses renderer / utility / gpu-process back into the browser
   process, dodging:
   - DXMT Issue #141 (no cross-process D3D11 swapchain)
   - Wine's flaky winsock path inside Chromium's out-of-process
     NetworkService
4. **`-noverifyfiles -no-cef-sandbox -cef-single-process`** passed to
   `Steam.exe` so the wrapper is not checksum-swapped back to Valve's
   binary at boot.
5. **`WINEDLLOVERRIDES`** chains the pieces above:
   `dxgi,d3d11,d3d10core=n,b` (DXMT native for games)
   `bcrypt=b;ncrypt=b` (Wine builtin to avoid BoringSSL conflicts)
   `gameoverlayrenderer,gameoverlayrenderer64=d`
   (hard-disable Steam's overlay DLL injection; otherwise it hooks
   Unity's D3D11 and deadlocks `GfxDevice: creating device client`).
6. **Japanese font substitution** registry (`Replacements` under
   `HKCU\Software\Wine\Fonts\`) maps `MS Shell Dlg`, `MS UI Gothic`,
   `Tahoma`, `Segoe UI`, … to Hiragino Sans GB.
7. **`RetinaMode=n`** for the Wine Mac driver is registered but does
   not appear to be honoured by Unity 6000's resolution probe (the
   window still opens at raw-pixel 3840x2160 and ignores
   `-screen-width`).

## Known limits at v0.2

- The `--disable-gpu` setting applies to Chromium (Steam UI) only.
  Games still go through DXMT for D3D11 translation and therefore
  inherit whatever bugs DXMT has under macOS Tahoe + Wine 11.
- Heavy 3D titles are unlikely to work well on the CPU fallback
  Chromium path anyway; the goal here is 2D / idle titles.
- `scripts/05-fix-ssl.sh` offers `INSTALL_COREFONTS=1` as an opt-in;
  not required for Japanese UI.

## Why this project exists

Running the Windows build of Steam on a modern Mac is harder than it looks:

1. **Whisky** (the once-popular free GUI) has frozen on Wine 7.7 (2022). That
   version can no longer boot the 2026 Steam client — the bootstrapper dies
   with `Client version: no bootstrapper found` in a 10-second crash loop.
2. **Apple's Game Porting Toolkit 1.1** (free) is also Wine 7.7 and hits the
   same ceiling.
3. **Homebrew's `wine-stable` / `wine@devel`** (Wine 11.x, 2026) boot the
   client, but CEF / Chrome 126 inside Steam paints a **black window** due
   to an ANGLE / Direct3D-over-OpenGL mismatch on Apple Silicon. This is
   tracked upstream as [DXMT Issue #141](https://github.com/3Shain/dxmt/issues/141).
4. **CrossOver** (paid, ~$74/year) ships CodeWeavers' in-house patches and
   works out of the box — but this project is about the permanent-free path.

`steam-on-m1-wine` is the set of scripts, notes, and small helper binaries
that close the remaining gaps on the free path.

## Hardware / OS requirements

| Requirement   | Tested value                         |
| ------------- | ------------------------------------ |
| Mac           | MacBook Pro 13" M1 (2020), 16 GB     |
| macOS         | Tahoe 26.4 (Build 25E246)            |
| CPU features  | arm64 + Rosetta 2                    |
| Xcode         | Command Line Tools installed         |
| Homebrew      | 5.1.x, prefix `/opt/homebrew`        |
| Disk headroom | ~10 GB (Wine + Steam + game assets)  |

Other M-series chips and macOS 15 (Sequoia) are likely compatible but not
currently validated in this repo.

## What it installs

| Component            | Source                              | Role                       |
| -------------------- | ----------------------------------- | -------------------------- |
| `wine-stable`        | Homebrew Cask (Gcenx)               | Wine 11.0 runtime          |
| `winetricks`         | Homebrew formula                    | Prefix tweaks              |
| `gstreamer-runtime`  | Homebrew Cask                       | Wine audio/video codecs    |
| Japanese system fonts| `/System/Library/` (user-owned)     | Steam UI glyphs            |
| DXMT                 | Official GitHub Release (tagged)    | D3D11 → Metal layer        |
| Steam client         | `cdn.cloudflare.steamstatic.com`    | Installed on demand        |

**Steam binaries are never committed to this repository.** They are fetched
from the official Valve CDN the first time you run `scripts/03-install-steam.sh`.

## Quick start

```bash
git clone https://github.com/<you>/steam-on-m1-wine.git
cd steam-on-m1-wine

# Run each step in order. Every script is idempotent —
# rerunning after a fix is safe.
scripts/00-prereqs.sh
scripts/01-install-wine.sh     # needs one sudo prompt for GStreamer .pkg
scripts/02-setup-prefix.sh
scripts/03-install-steam.sh
scripts/04-install-dxmt.sh
scripts/05-fix-ssl.sh
scripts/06-install-wrapper.sh

# Then, any time you want to play:
scripts/launch-steam.sh
```

## Repository layout

```
.
├── README.md                # This file
├── LICENSE                  # MIT + third-party notices
├── docs/
│   ├── architecture.md      # How the pieces fit together
│   ├── troubleshooting.md   # Symptoms → fixes
│   └── references.md        # Upstream issues & commits
├── scripts/
│   ├── lib/common.sh        # Logging + env helpers shared by all scripts
│   ├── 00-prereqs.sh        # Verify Rosetta / Homebrew / Xcode
│   ├── 01-install-wine.sh   # Install Wine + winetricks via brew
│   ├── 02-setup-prefix.sh   # Create WINEPREFIX, copy JP fonts
│   ├── 03-install-steam.sh  # Download SteamSetup.exe, silent install
│   ├── 04-install-dxmt.sh   # Vendor DXMT DLLs into the prefix
│   ├── 05-fix-ssl.sh        # TLS/Winsock workarounds
│   ├── 06-install-wrapper.sh# Install steamwebhelper wrapper
│   └── launch-steam.sh      # Launch with the agreed flag set
└── wrapper/
    ├── src/                 # C source for the steamwebhelper wrapper
    └── Makefile             # Cross-compile via x86_64-w64-mingw32-gcc
```

## Design principles

- **Idempotent scripts.** Running any step twice is a no-op if already done.
- **No secrets, no tokens.** The project never asks for a Steam password or
  Steam Guard code — those are typed into Steam's own login dialog.
- **No binary redistribution.** Everything that has licensing friction
  (Steam, Windows DLLs) is fetched live from the vendor.
- **Explicit versions.** Every upstream URL is pinned to a specific tag
  / commit so behaviour is reproducible long after this README is written.

## License

MIT. See [LICENSE](LICENSE) for the full text and for the third-party
component attributions.
