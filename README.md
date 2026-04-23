# steam-on-m1-wine

Run the Windows **Steam** client and D3D11 games on an Apple Silicon
Mac. Free path — no CrossOver, no paid layer. One install command, one
Dock icon.

Verified on an M1 MacBook Pro 13" (2020) running macOS Tahoe 26.4, with
the 32-bit Unity 6000 title 幻獣大農場 (Steam AppID 3659410)
rendering end-to-end via DXMT.

---

## Quick start

```bash
git clone https://github.com/notpop/steam-on-m1-wine.git
cd steam-on-m1-wine
bash install.sh
```

That installs Wine 11, sets up a Steam-only prefix, fetches the real
Steam installer from Valve's CDN, builds & deploys the
`steamwebhelper` wrapper, drops a macOS **Steam on M1 Wine.app** into
`~/Applications`. Launch with the Dock icon (or the `.app`), log in
with your Valve account. **The Steam UI is usable at this point.**

To also run D3D11 games (Unity / Unreal / Monogame titles), you need
an extra DXMT fork build and a Wine rebuild with
`-fvisibility=default`. Both take ~30 min each. Full step-by-step
instructions in [`docs/building-for-games.md`](docs/building-for-games.md).

Optional — pin the app to the Dock (idempotent):

```bash
bash scripts/10-add-to-dock.sh
```

---

## Why this project exists

Running the Windows build of Steam on a modern Mac is harder than it
looks on the free path:

| | Price | Wine ver | 2026 Steam boot | D3D11 games | macOS Tahoe 26 |
| --- | --- | --- | --- | --- | --- |
| **Whisky** | free | 7.7 (frozen 2022) | ✗ (bootstrapper crash loop) | ✗ | ✗ |
| **Apple Game Porting Toolkit 1.1** | free | 7.7 | ✗ (same ceiling) | ✗ | ✗ |
| **Homebrew `wine-stable` 11.0** | free | 11.0 | black window ([DXMT #141](https://github.com/3Shain/dxmt/issues/141)) | transparent window | boots |
| **CrossOver** | paid (~¥10k/yr) | in-house | ✓ | ✓ | ✓ |
| **this repo (v0.6)** | free | 11.0 + rebuild | ✓ | ✓ | ✓ |

Whisky and GPTK have been frozen at Wine 7.7 since 2022, and Valve's
2026 Steam client will not boot on them. Homebrew's `wine-stable` 11.0
does boot Steam, but CEF 126 paints the browser window black and
D3D11 titles render to transparent windows.

This repo closes the gap on the free path by combining four fixes that
are not available off the shelf:

1. **A custom `steamwebhelper` wrapper** that forces CEF into
   `--disable-gpu --single-process` (sidesteps the black-window bug
   and Wine's winsock NetworkService issue).
2. **A Wine 11 build with `-fvisibility=default`**, so macdrv's
   public API is callable by third-party Metal layers via `dlsym`.
3. **A DXMT fork** that rewrites `_CreateMetalViewFromHWND` around
   two Wine 11 bugs: (a) the internal `macdrv_win_data` struct no
   longer exposes a usable NSView at swap-chain creation, and
   (b) wrapping macdrv's Metal helpers in Wine's own `OnMainThread`
   re-enters and deadlocks.
4. **A virtual desktop wrapper** around Steam so the Wine session
   runs inside a single, display-sized macOS window instead of
   seizing the native fullscreen space.

Each fix is explained with code references in
[`docs/dxmt-diagnosis.md`](docs/dxmt-diagnosis.md); upstream bug
reports are drafted in [`docs/upstream-issue-draft.md`](docs/upstream-issue-draft.md)
and [`docs/wine-bugzilla-draft.md`](docs/wine-bugzilla-draft.md).

---

## What works (v0.6)

On the reference machine (M1 MacBook Pro 13" 2020, 16 GB, macOS Tahoe
26.4):

- **Steam UI**: fully rendered, Japanese text via Hiragino Sans GB,
  authenticated login against Valve's servers, library + store
  navigation.
- **Games**: the 32-bit Unity 6000 title 幻獣大農場 launches from the
  library, passes `D3D11CreateDevice`, renders its title screen and
  farm scene, and `IDXGISwapChain::Present1` returns `hr=0x0` every
  frame.
- **Coexistence**: the whole Wine session runs inside a single macOS
  window sized to the user's display (auto-detected), so Cmd+Tab,
  Mission Control, and Dock Hide behave as expected.

## Hardware / OS requirements

| Requirement | Tested value |
| --- | --- |
| Mac | Apple Silicon (M1 reference; M2/M3/M4 assumed compatible) |
| macOS | Tahoe 26.4. Sequoia 15 assumed compatible, not validated. |
| CPU features | arm64 + Rosetta 2 |
| Xcode | Command Line Tools |
| Homebrew | 5.1.x, prefix `/opt/homebrew` |
| Disk | ~20 GB free |

Rosetta 2 is installed on first `bash install.sh` run if missing.

## Game launch options

Steam's Launch Options are per-game and per-account, so this repo
cannot pre-populate them. For each Unity D3D11 title, open
`Library → (game) → right-click → Properties → General → Launch
Options` and paste:

```
-force-d3d11-no-singlethreaded -screen-fullscreen 0
```

- `-force-d3d11-no-singlethreaded` — Unity creates the D3D11 device
  in multi-threaded mode. Retained defensively.
- `-screen-fullscreen 0` — force windowed mode. The game draws inside
  the Wine virtual desktop instead of grabbing macOS fullscreen.

## Known limits

- The Wine virtual desktop window is borderless by construction, so
  **the window itself has no draggable title bar**. It is auto-sized
  to your display on launch. Use Cmd+Tab / Mission Control to manage
  focus.
- Heavy 3D titles probably will not run well: Steam UI is CPU-raster
  only (`--disable-gpu`), and DXMT's D3D11 coverage still has gaps.
  This repo targets 2D / idle / low-spec titles.
- Steam Launch Options are per-user and stored in
  `localconfig.vdf`; the repo deliberately does not write to that
  file to avoid account-corruption risk.
- Virtual desktop resolution follows the display at launch time.
  Moving Steam to a different display requires a relaunch.

## What gets installed

| Component | Source | Role |
| --- | --- | --- |
| `wine-stable` | Homebrew Cask (Gcenx) | Wine 11.0 runtime |
| `winetricks` | Homebrew formula | Prefix tweaks |
| `gstreamer-runtime` | Homebrew Cask | Wine A/V codecs |
| Japanese system fonts | `/System/Library/` (user-owned) | Steam UI glyphs |
| Steam client | `cdn.cloudflare.steamstatic.com` | Installed on demand |
| steamwebhelper wrapper | Built from `wrapper/` (mingw-w64) | CEF flag injector |
| `.app` bundle | Generated locally in `~/Applications` | Dock launcher |
| DXMT v0.74 | Official GitHub Release | D3D11 → Metal (fallback) |

D3D11 gaming additionally requires the v0.6 DXMT fork and a
visibility-patched Wine build; see
[`docs/building-for-games.md`](docs/building-for-games.md).

Steam binaries and Windows DLLs are **never** redistributed through
this repository — everything with licensing friction is fetched live
from the vendor the first time the corresponding script runs.

## Repository layout

```
.
├── README.md                        # You are here
├── install.sh                       # One-shot Steam-UI bootstrap
├── LICENSE
├── docs/
│   ├── building-for-games.md        # Extra steps for D3D11 games
│   ├── architecture.md              # How the pieces fit together
│   ├── troubleshooting.md           # Symptoms → fixes
│   ├── references.md                # Upstream issues & commits
│   ├── dxmt-diagnosis.md            # Full root-cause chronology
│   ├── upstream-issue-draft.md      # Draft for 3Shain/dxmt
│   └── wine-bugzilla-draft.md       # Draft for WineHQ Bugzilla
├── scripts/
│   ├── 00-prereqs.sh
│   ├── 01-install-wine.sh
│   ├── 02-setup-prefix.sh
│   ├── 03-install-steam.sh
│   ├── 04-install-dxmt.sh           # v0.74 fallback
│   ├── 05-fix-ssl.sh
│   ├── 06-install-wrapper.sh
│   ├── 09-install-macos-app.sh      # Generate the Dock .app
│   ├── 10-add-to-dock.sh            # Optional: pin to Dock
│   ├── launch-steam.sh              # Manual launch
│   ├── lib/common.sh                # Shared helpers
│   ├── assets/                      # .reg fragments
│   └── experimental/
│       ├── 07-build-dxmt-from-fork.sh   # v0.6 DXMT fork build
│       ├── 04b-install-dxmt-nightly.sh
│       ├── 04b-revert-to-dxmt-v0.74.sh
│       └── run-with-dxmt-debug.sh
└── wrapper/
    ├── src/                         # C source (mingw-w64 target)
    └── Makefile
```

## Design principles

- **Idempotent scripts.** Every step is safe to re-run.
  `install.sh` short-circuits any work that is already done.
- **No secrets, no tokens.** The project never asks for a Steam
  password or Steam Guard code — those go into Steam's own dialog.
- **No binary redistribution** of anything with licensing friction
  (Steam, Windows DLLs). Fetched live from the vendor.
- **Explicit versions.** Upstream URLs are pinned to specific
  tags / commits so behaviour is reproducible long after this
  README was written.
- **Upstream-able fixes.** The DXMT fork diff is ~150 lines over
  upstream, no dead code. See
  [`docs/upstream-issue-draft.md`](docs/upstream-issue-draft.md)
  for the write-up aimed at 3Shain's DXMT repo.

## References

- Wine macdrv visibility patch origin:
  [3Shain/wine@6197fc7](https://github.com/3Shain/wine/commit/6197fc7)
- DXMT upstream: <https://github.com/3Shain/dxmt>
- DXMT fork used here:
  `github.com/notpop/dxmt@debug/present-path-tracing`
- Cross-process swapchain issue:
  [DXMT #141](https://github.com/3Shain/dxmt/issues/141)
- Full technical diagnosis:
  [`docs/dxmt-diagnosis.md`](docs/dxmt-diagnosis.md)

## License

MIT. See [LICENSE](LICENSE) for the full text and third-party
attributions.
