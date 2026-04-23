# steam-on-m1-wine

Reproducible, script-driven setup for running the Windows **Steam**
client **and D3D11 games** on an Apple Silicon Mac via Homebrew-packaged
Wine — no paid compatibility layer required. One command, one Dock
icon.

> **Status:** v0.6 — Steam UI works, and D3D11 games render.
> Validated on a 32-bit Unity 6000 title
> (幻獣大農場 / MonsterFarm) on M1 MacBook Pro 13" (2020), macOS Tahoe
> 26.4. The remaining transparent-window issue tracked through v0.2–v0.5
> turned out to be *three* stacked bugs; only the first (Wine symbol
> visibility) had been reported publicly. The other two — macdrv struct
> ABI drift, and `OnMainThread` re-entrance deadlock — are fixed in the
> DXMT fork that this repo builds. Full write-up in
> [`docs/dxmt-diagnosis.md`](docs/dxmt-diagnosis.md) (Phase D).

## Why this project exists

Running the Windows build of Steam — and the games you buy on it — on a
modern Mac is harder than it looks on the free path:

| | Price | Wine version | Steam 2026 boot | D3D11 games | macOS Tahoe 26 |
| --- | --- | --- | --- | --- | --- |
| **Whisky** | free | 7.7 (frozen 2022) | ✗ (bootstrapper crash loop) | ✗ | ✗ |
| **Apple Game Porting Toolkit 1.1** | free | 7.7 | ✗ (same ceiling) | ✗ | ✗ |
| **Homebrew `wine-stable` 11.0** | free | 11.0 | black window (DXMT issue #141) | transparent window | boots |
| **CrossOver** | paid (~¥10k/yr) | in-house | ✓ | ✓ | ✓ |
| **this repo (v0.6)** | free | 11.0 + rebuild | ✓ | ✓ | ✓ |

Whisky and GPTK have been frozen at Wine 7.7 since 2022, and Valve's
2026 Steam client will not boot on them. Homebrew's `wine-stable` 11.0
does boot Steam, but CEF / Chrome 126 paints the browser window black
(DXMT [#141](https://github.com/3Shain/dxmt/issues/141)) and D3D11
titles render to transparent windows.

This repo closes the gap on the free path by combining four fixes that
are not available off the shelf:

1. **A custom `steamwebhelper` wrapper** that forces CEF into
   `--disable-gpu --single-process` (sidesteps the black-window bug and
   Wine's winsock NetworkService issue).
2. **A Wine 11 build with `-fvisibility=default`**, so macdrv's public
   API is callable via `dlsym` by third-party Metal layers.
3. **A DXMT fork** that rewrites `_CreateMetalViewFromHWND` around two
   Wine 11 bugs: (a) the internal `macdrv_win_data` struct no longer
   exposes a usable NSView at swap-chain creation, and (b) wrapping
   macdrv's Metal helpers in Wine's own `OnMainThread` re-enters and
   deadlocks.
4. **A virtual desktop wrapper** around Steam so the Wine session runs
   inside a single, display-sized macOS window instead of seizing the
   native fullscreen space.

Each fix is explained in
[`docs/dxmt-diagnosis.md`](docs/dxmt-diagnosis.md) and has a matching
upstream-issue draft in [`docs/`](docs/).

## What works (v0.6)

On the reference machine (M1 MacBook Pro 13" 2020, 16 GB, macOS Tahoe
26.4):

- **Steam UI**: fully rendered, Japanese text via Hiragino Sans GB,
  authenticated login against Valve's servers, library & store
  navigation.
- **Games**: 幻獣大農場 (32-bit Unity 6000) launches from the library,
  passes `D3D11CreateDevice`, renders its title screen and farm scene,
  and `IDXGISwapChain::Present1` returns `hr=0x0` every frame.
- **Coexistence**: the whole Wine session runs inside a single macOS
  window sized to the user's display (auto-detected), so Cmd+Tab,
  Mission Control, and Dock Hide behave as expected.

## Hardware / OS requirements

| Requirement | Tested value |
| --- | --- |
| Mac | Apple Silicon (M1 reference; M2/M3/M4 assumed compatible, not validated) |
| macOS | Tahoe 26.4 (Build 25E246). Sequoia 15 assumed compatible, not validated. |
| CPU features | arm64 + Rosetta 2 |
| Xcode | Command Line Tools |
| Homebrew | 5.1.x, prefix `/opt/homebrew` |
| Disk headroom | ~20 GB (Wine + Steam + game assets + DXMT build toolchain) |

## Quick start

```bash
git clone https://github.com/notpop/steam-on-m1-wine.git
cd steam-on-m1-wine

# One-shot: prereqs → wine → prefix → Steam install → DXMT → wrapper →
# macOS .app bundle. Idempotent; re-running is a no-op if already done.
bash install.sh

# Recommended: pin the app to the Dock
bash scripts/10-add-to-dock.sh

# For D3D11 games (adds the v0.6 DXMT fork):
bash scripts/experimental/07-build-dxmt-from-fork.sh
```

After `install.sh`, there are three equivalent ways to launch Steam:

- **Dock icon** (if you ran `10-add-to-dock.sh`) — one click.
- `open ~/Applications/Steam\ on\ M1\ Wine.app`
- `bash scripts/launch-steam.sh --detach`

Launching with DXMT debug logging (writes to `/tmp/dxmt-logs/`):

```bash
bash scripts/experimental/run-with-dxmt-debug.sh
```

## Game-specific launch options (manual, per game)

Steam's Launch Options are per-game and per-Steam-account, so the repo
cannot pre-populate them. In the game's Steam Library entry:

1. Right-click → Properties → General → Launch Options
2. Paste a baseline set appropriate for Unity titles, e.g.:
   ```
   -force-d3d11-no-singlethreaded -screen-fullscreen 0
   ```
3. Close the dialog; Steam auto-saves.

What the flags do:

- `-force-d3d11-no-singlethreaded` — ask Unity to create the D3D11
  device in multi-threaded mode. Retained defensively; may be
  removable on v0.6 for games that render correctly without it.
- `-screen-fullscreen 0` — force windowed mode, so the game draws inside
  the Wine virtual desktop instead of asking for macOS fullscreen.
- (Optional) `-screen-width W -screen-height H` — pin the internal
  render resolution. Omit to let Unity use the virtual desktop's native
  resolution (preserves aspect ratio).

## Known limits

- **The game window cannot be dragged.** Wine's virtual desktop window
  is `WS_POPUP` / borderless by construction, so macOS gives it no
  title bar. The virtual desktop is sized to the display on startup;
  the user interacts with it via Mission Control / Cmd+Tab, not by
  dragging. Opt out with `WINE_VIRTUAL_DESKTOP=""` if you prefer
  per-window NSWindows (Steam UI becomes draggable, games still
  cannot be because Unity's `-popupwindow` / Canvas Scaler logic
  strips window chrome).
- **Heavy 3D titles are unlikely to run well** on the CPU Chromium
  path the wrapper uses for the Steam UI. The repo targets 2D / idle
  / low-spec titles. Unity engine games render through DXMT on the GPU
  and can hit its current coverage (no geometry shaders, etc).
- **`-force-d3d11-no-singlethreaded`** is retained defensively; it may
  not be required on v0.6. See the tracking task in the repo.
- **Steam Launch Options are per-user**; this repo cannot edit
  `localconfig.vdf` without risking account corruption, so the
  per-game flags above are documented as a manual step.
- **Virtual desktop resolution follows the display at launch time.**
  If you move Steam to a different display, exit and relaunch.

## What gets installed

| Component | Source | Role |
| --- | --- | --- |
| `wine-stable` | Homebrew Cask (Gcenx) | Wine 11.0 runtime |
| `winetricks` | Homebrew formula | Prefix tweaks |
| `gstreamer-runtime` | Homebrew Cask | Wine audio/video codecs |
| Japanese system fonts | `/System/Library/` (user-owned) | Steam UI glyphs |
| DXMT fork | `github.com/notpop/dxmt@debug/present-path-tracing` | D3D11 → Metal |
| steamwebhelper wrapper | Built from `wrapper/` (mingw-w64) | CEF flag injector |
| Steam client | `cdn.cloudflare.steamstatic.com` | Installed on demand |
| macOS `.app` bundle | Generated locally | Dock launcher |

Steam binaries and Windows DLLs are **never** redistributed through
this repository — everything with licensing friction is fetched live
from the vendor the first time the corresponding script runs.

## Repository layout

```
.
├── README.md                 # This file
├── install.sh                # One-shot orchestrator
├── LICENSE                   # MIT + third-party notices
├── docs/
│   ├── architecture.md       # How the pieces fit together
│   ├── troubleshooting.md    # Symptoms → fixes
│   ├── references.md         # Upstream issues & commits
│   ├── dxmt-diagnosis.md     # Full multi-phase root-cause writeup
│   ├── upstream-issue-draft.md  # Draft for the DXMT repo
│   └── wine-bugzilla-draft.md   # Draft for WineHQ Bugzilla
├── scripts/
│   ├── lib/common.sh
│   ├── 00-prereqs.sh
│   ├── 01-install-wine.sh
│   ├── 02-setup-prefix.sh
│   ├── 03-install-steam.sh
│   ├── 04-install-dxmt.sh          # v0.74 official fallback
│   ├── 05-fix-ssl.sh
│   ├── 06-install-wrapper.sh
│   ├── 09-install-macos-app.sh     # Generate the Dock .app bundle
│   ├── 10-add-to-dock.sh           # Optional: pin to Dock via defaults
│   ├── launch-steam.sh             # Manual launch
│   └── experimental/
│       ├── 07-build-dxmt-from-fork.sh
│       ├── 04b-install-dxmt-nightly.sh
│       ├── 04b-revert-to-dxmt-v0.74.sh
│       └── run-with-dxmt-debug.sh
└── wrapper/
    ├── src/                  # C source for the steamwebhelper wrapper
    └── Makefile              # Cross-compile via x86_64-w64-mingw32-gcc
```

## Design principles

- **Idempotent scripts.** Running any step twice is a no-op if the work
  is already done. `install.sh` can be re-run any time.
- **No secrets, no tokens.** The project never asks for a Steam
  password or Steam Guard code — those are typed into Steam's own
  login dialog.
- **No binary redistribution** of anything with licensing friction
  (Steam, Windows DLLs). Everything is fetched live from the vendor.
- **Explicit versions.** Upstream URLs are pinned to tags / commits so
  behaviour is reproducible long after this README was written.
- **Upstream-able fixes.** The DXMT fork diff is ~150 lines over the
  upstream commit it forks from, with no dead code. See
  [`docs/upstream-issue-draft.md`](docs/upstream-issue-draft.md) for
  the write-up aimed at 3Shain's DXMT repo.

## References

- Wine macdrv visibility patch origin:
  [3Shain/wine@6197fc7](https://github.com/3Shain/wine/commit/6197fc7)
- DXMT upstream: <https://github.com/3Shain/dxmt>
- DXMT fork used here:
  `github.com/notpop/dxmt@debug/present-path-tracing`
- Cross-process swapchain issue:
  [DXMT #141](https://github.com/3Shain/dxmt/issues/141)
- Full technical diagnosis: [`docs/dxmt-diagnosis.md`](docs/dxmt-diagnosis.md)

## License

MIT. See [LICENSE](LICENSE) for the full text and third-party component
attributions.
