# DXMT transparent-window diagnosis (2026-04-23)

Final write-up of why every 32-bit Unity game launched via Steam on
Apple Silicon stayed transparent (the issue that motivated v0.1
through v0.3 of this project).

## TL;DR

The Wine distribution we were running (Homebrew `wine-stable` 11.0,
ultimately Gcenx's Mach-O build) ships `winemac.so` with **zero
public symbols**. DXMT's `winemetal_unix.c` probes `dlsym(RTLD_DEFAULT,
"get_win_data")` and friends, gets `NULL` for all of them, and
silently returns an empty `ret_view` / `ret_layer` to the caller.
The caller treats that as success, so:

- `IDXGISwapChain::Present1` runs happily
- Chromium / Unity think they submitted a frame
- but there is **no `CAMetalLayer` attached to the `NSView`**, so
  macOS shows whatever is behind the Wine window → transparent

## Evidence

### 1. DXMT stderr (enabled by our `DXMT_DEBUG_METAL_VIEW=1`
patch on `debug/present-path-tracing` in the fork)

`docs/evidence/winemetal-stderr.txt`:

```
[dxmt/winemetal] CreateMetalViewFromHWND:
  hwnd=0x90190 macdrv_functions=0x0
  get_win_data=0x0 release_win_data=0x0
  create_metal_view=0x0 get_metal_layer=0x0
[dxmt/winemetal] CreateMetalViewFromHWND: one of the macdrv
  function pointers is NULL, silently returning empty view/layer
```

All four `dlsym` probes **and** the combined `macdrv_functions`
structure probe return `NULL`. The original upstream code has no
diagnostic for this path at all — see upstream
`src/winemetal/unix/winemetal_unix.c`, `_CreateMetalViewFromHWND`
(commit `43a16e9`, lines 1596–1608): the `if (…)` block is skipped
and `STATUS_SUCCESS` is returned with `ret_view` / `ret_layer`
never touched.

### 2. `nm -g` on the two Wine builds

`docs/evidence/winemac-so-gcenx-nm.txt`:

```
# Gcenx wine-stable 11.0 winemac.so
# Exported T (defined global text): 0
```

`docs/evidence/winemac-so-3shain-nm.txt`:

```
# 3Shain wine v8.16-3shain winemac.so
# Exported T: 17, including:
0000000000027b70 T _get_win_data
000000000004bd20 T _macdrv_view_create_metal_view
000000000004bec0 T _macdrv_view_get_metal_layer
000000000004bfb0 T _macdrv_view_release_metal_view
0000000000027bc0 T _release_win_data
000000000004bcc0 T _macdrv_create_metal_device
000000000004bcf0 T _macdrv_release_metal_device
0000000000027cc0 T _macdrv_get_client_cocoa_view
0000000000027c60 T _macdrv_get_cocoa_view
```

## Why this matters

DXMT's `docs/DEVELOPMENT.md` recommends building against a Wine whose
build tree has these symbols and then placing the prebuilt DLLs under
`<wine>/lib/wine/<arch>-windows/`. That installation guide implicitly
assumes the **runtime** Wine also has the same symbol visibility.
The CI artefact (`v8.16-3shain/wine.tar.gz`) is built with
`-fvisibility=default` (or equivalent) and does expose them; anything
built without that setting ( — Gcenx's, presumably Wine's default
release configuration, and at least some CrossOver release branches)
does not.

Because `_CreateMetalViewFromHWND` has no `ERR()` for the all-NULL
case, the failure is silent. Users see a transparent window and no
matching log line, so the common debugging advice ("enable
`DXMT_LOG_LEVEL=debug`") doesn't surface anything.

## Proposed fixes

Two independent fixes should both be accepted upstream:

1. **Make the failure loud.** In
   `src/winemetal/unix/winemetal_unix.c` `_CreateMetalViewFromHWND`,
   add a permanent `fprintf(stderr, …)` on the branch where one or
   more of the four pointers is `NULL`. Our fork branch
   `debug/present-path-tracing` contains a prototype under
   `DXMT_DEBUG_METAL_VIEW=1`; a production version would not need
   the environment gate.

2. **Document the Wine symbol-visibility requirement** in
   `docs/DEVELOPMENT.md` and the project README. Concretely:
   "DXMT requires a Wine build that exports `winemac.drv` symbols
   from `winemac.so`. Ad-hoc releases such as Homebrew's
   `wine-stable` 11.0 (Gcenx) build with `-fvisibility=hidden`
   and are not supported at runtime even if DXMT was compiled
   against them."

A third fix — reaching past `RTLD_DEFAULT` and `dlopen`-ing
`winemac.so` directly — does **not** work, because
`-fvisibility=hidden` hides the symbols from `dlsym` too; they
simply aren't in the dynamic symbol table of the `.so`.

## What this means for this project

- v0.1–v0.3 of `steam-on-m1-wine` stays correct: Steam UI works,
  because the CEF path uses `--disable-gpu` and never goes through
  `_CreateMetalViewFromHWND`.
- Running any game that relies on `IDXGISwapChain` → Metal is
  currently blocked on Gcenx Wine 11.0, independent of any DXMT
  tweak we could apply locally.

## Phase C: Wine 11 rebuilt with `-fvisibility=default`

Reconfigured Wine 11.0 with `CFLAGS=-fvisibility=default
CXXFLAGS=-fvisibility=default`, `make -j8`, then swapped the
resulting `dlls/winemac.drv/winemac.so` over Gcenx's (backup kept
as `winemac.so.gcenx-backup`). Results:

- `nm -g | awk '$2=="T"' | wc -l` = **200** (from **0** on the
  Gcenx build, **17** on 3Shain's v8.16 build). The whole public
  surface of `winemac.drv` is now visible.
- DXMT's `dlsym` probes **all succeed**:
  ```
  get_win_data=0x20c42de10   release_win_data=0x20c42de90
  macdrv_view_create_metal_view=0x20c40eec0
  macdrv_view_get_metal_layer=0x20c40f0e0
  ```
- `get_win_data(hwnd)` returns a valid `struct macdrv_win_data*`.

### But a second wall appears

```
[dxmt/winemetal] CreateMetalViewFromHWND: hwnd=0x3019a
  win_data=0x600001a2c000
  client_cocoa_view=0x0       ← NULL
  view=0x0  layer=0x0
err:   Failed to create metal view, ...
```

The struct Wine returns has **`client_cocoa_view == NULL`** at the
time DXMT inspects it. So even with the visibility fix, DXMT cannot
hand a usable `NSView` to `macdrv_view_create_metal_view`. The
evidence capture is in
`docs/evidence/winemetal-stderr-after-fvisibility.txt`.

Why: in `dlls/winemac.drv/window.c` Wine 11 populates
`client_cocoa_view` from Cocoa callbacks that run on the main
thread after the window is fully created. DXMT grabs
`win_data->client_cocoa_view` synchronously from a thread that
raced with that initialisation. 3Shain's Wine 8.16 fork didn't
have this race (the field was set up front); between 8.16 and 11.0
the macdrv window-lifecycle code was reorganised.

This makes a **source-patch-level fix** a bigger change than just
exposing symbols:

- either DXMT must wait-or-retry until Cocoa populates the view
- or Wine's `winemac.drv` must publish a synchronous
  `macdrv_get_or_create_cocoa_view(hwnd)` helper

Both are non-trivial. They are why this repo can document the
problem exhaustively but cannot unblock gameplay on today's hard
dependencies (Wine 11 + macOS Tahoe 26 + DXMT v0.74 / master).

## Reproduction steps

Starting from a working v0.3 setup:

```bash
# 1. Build DXMT from the fork with diagnostic tracing
export MESON=$HOME/Library/Python/3.14/bin/meson
cd ~/dev/dxmt && git checkout debug/present-path-tracing
cd ~/dev/steam-on-m1-wine
scripts/experimental/07-build-dxmt-from-fork.sh

# 2. Launch Steam with DXMT_DEBUG_METAL_VIEW=1 and log level debug
scripts/experimental/run-with-dxmt-debug.sh

# 3. Start a Unity game from Steam (幻獣大農場 here) and let it
#    reach a transparent window
# 4. Inspect the capture
grep 'dxmt/winemetal' /var/folders/**/steam-on-m1-wine.log

# 5. Sanity-check the runtime Wine's winemac.so symbols
nm -g "/Applications/Wine Stable.app/Contents/Resources/wine/lib/wine/x86_64-unix/winemac.so" \
    | awk '$2=="T"'
```

`docs/evidence/*.txt` contains the capture used above, so the
report can be re-verified from the repository alone.
