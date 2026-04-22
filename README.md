# steam-on-m1-wine

Reproducible, script-driven setup for running the Windows **Steam** client
on an Apple Silicon (M-series) Mac via Homebrew-packaged Wine — no paid
compatibility layer required.

> **Status:** v0.1 — Steam UI renders, Japanese reads, login works.
> Tracks the upstream state of Wine, DXMT, and Steam as of April 2026.
> Targets macOS Tahoe 26.x on M1 / M2 / M3 / M4 hardware.

## What works (v0.1)

On the reference machine (M1 MacBook Pro 13" 2020, 16 GB, macOS Tahoe
26.4) `scripts/launch-steam.sh` produces a Steam window with fully
rendered store, library, and navigation, all Japanese UI text rendered
with Hiragino Sans GB, and a working login session against Valve's
servers. Stats from the successful run:

- Steam client build 1773426488 (CEF / Chromium 126.0.6478.183)
- Wine 11.0 stable (Homebrew cask, x86_64 under Rosetta 2)
- `--type=` subprocesses collapsed to a single `crashpad-handler`
- No more `cross-process swapchain not supported` errors
- No new `SwapChain11::reset` / `EGL_BAD_ALLOC` / `handshake failed`
  entries in `cef_log.txt` after cold launch

## How it gets there

The working combination is:

1. **Wine 11.0 stable** (Homebrew cask, quarantine stripped)
2. **DXMT v0.74** installed into the Wine bundle and prefix
   (kept for future GPU-accelerated runs; bypassed in the current
   `--disable-gpu` launch configuration)
3. A **self-compiled `steamwebhelper` wrapper** that renames the Valve
   binary to `steamwebhelper_real.exe` and prepends
   `--disable-gpu --single-process` to every invocation. This
   collapses renderer / utility / gpu-process back into the browser
   process, dodging:
   - DXMT Issue #141 (no cross-process D3D11 swapchain)
   - Wine's flaky winsock path inside Chromium's out-of-process
     NetworkService
4. **`-noverifyfiles -no-cef-sandbox`** passed to `Steam.exe` so the
   wrapper is not checksum-swapped back to Valve's binary at boot
5. **Japanese font substitution** registry (`Replacements` under
   `HKCU\Software\Wine\Fonts\`) so logical Windows font names resolve
   to Hiragino Sans GB instead of Liberation Sans

## Known limits at v0.1

- `--disable-gpu` is a software-raster fallback. The DXMT pieces are
  in place for the day DXMT ships cross-process swapchain support,
  but the current launch configuration does not exercise them.
- Heavy 3D titles will not be smooth through Wine's CPU composite;
  this is intended for 2D / idle titles like 幻獣大農場.
- `scripts/05-fix-ssl.sh` offers `INSTALL_COREFONTS=1` as an opt-in,
  but it is not required for Japanese UI to render in v0.1.

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
