# Draft: short bug report for 3Shain/dxmt

Target: <https://github.com/3Shain/dxmt/issues/new>

This is intentionally a **short report**, not a PR. The real fix
for the underlying problem belongs in Wine (see
`docs/wine-bugzilla-draft.md`). What the DXMT side can usefully do
is make the failure visible so the next user saves the debugging
time this took.

---

## Title

`_CreateMetalViewFromHWND` silently returns empty view/layer when `winemac.so` exports no symbols

## Body

### What I saw

On macOS Tahoe 26.4 + Apple Silicon M1 + Homebrew `wine-stable` 11.0
(the Gcenx cask), any Direct3D 11 title run through DXMT opens a
window that stays transparent. No `ERR(…)` / `WARN(…)` is emitted;
`DXMT_LOG_LEVEL=debug` produces empty
`<exe>_{d3d11,dxgi}.log` files for the game.

Upstream of the symptom is `_CreateMetalViewFromHWND` in
`src/winemetal/unix/winemetal_unix.c` (lines 1575–1610 on commit
`43a16e9`). It probes `dlsym(RTLD_DEFAULT, "macdrv_functions")`,
then `dlsym(RTLD_DEFAULT, "get_win_data")`, etc. On the Wine I am
running every probe returns `NULL`, so the `if (…)` block is
skipped and the function returns `STATUS_SUCCESS` with
`ret_view = ret_layer = 0`. The caller treats that as success, the
swapchain is created, `Present1` runs, but nothing ever attaches to
a `CAMetalLayer`.

### Why the probes fail on my machine

The `winemac.so` in this Wine build exports **zero** text symbols:

```
$ nm -g /Applications/Wine\ Stable.app/Contents/Resources/wine/lib/wine/x86_64-unix/winemac.so \
    | awk '$2=="T"' | wc -l
0
```

Contrast the Wine you distribute at
`https://github.com/3Shain/wine/releases/tag/v8.16-3shain` (the one
`docs/DEVELOPMENT.md` and the CI use):

```
$ nm -g toolchains/wine/lib/wine/x86_64-unix/winemac.so \
    | awk '$2=="T"' | wc -l
17
# including _get_win_data, _macdrv_view_create_metal_view, …
```

The difference looks like it was introduced by your own commit
[3Shain/wine@6197fc7 "winemac: export essential apis"](https://github.com/3Shain/wine/commit/6197fc7).
Wine's `configure` unconditionally appends `-fvisibility=hidden`,
so upstream and any redistributed build that hasn't cherry-picked
that commit (including Gcenx's Homebrew cask) ends up with a
`winemac.so` that can't satisfy these `dlsym` calls. I have not
verified whether that is the only cause, but it is a sufficient
cause: applying `6197fc7` to a clean Wine source makes the symbols
appear.

### Addendum: the Wine visibility fix on its own is not sufficient

For what it's worth, rebuilding Wine 11.0 locally with
`CFLAGS=-fvisibility=default` restores all 200 public symbols in
`winemac.so` and makes every `dlsym` in `_CreateMetalViewFromHWND`
succeed. DXMT then calls `get_win_data(hwnd)` and gets a valid
`struct macdrv_win_data*`, but the `client_cocoa_view` field it
reads is `NULL`, because in Wine 11 `dlls/winemac.drv/window.c`
populates that member on Cocoa's main-thread callbacks after the
synchronous `alloc_win_data` path.

In other words the silent-return symptom is really two bugs
stacked on top of each other: (a) the symbols aren't exported, (b)
even when they are, the `client_cocoa_view` read races with
Cocoa. The proposed fixes below only address the diagnosability of
(a); (b) is a larger conversation between DXMT and Wine's macdrv.

### What I'd suggest

Happy to PR either or both, whichever you'd accept:

1. **Make the silent path loud.** Replace the `if (… && …)` block
   in `_CreateMetalViewFromHWND` with an `ERR(…)` on the
   "at least one pointer is NULL" branch, along the lines of
   ```c
   ERR("winemac.drv symbols not found via dlsym; the Wine runtime "
       "appears to have -fvisibility=hidden without the 3Shain "
       "patch. View/layer will be empty — Steam / games will show "
       "transparent windows.\n");
   ```
   A prototype of this (gated behind `DXMT_DEBUG_METAL_VIEW=1`) is
   on my fork branch
   [notpop/dxmt@debug/present-path-tracing](https://github.com/notpop/dxmt/tree/debug/present-path-tracing),
   commit `b8ebec5`.

2. **Write the Wine requirement into `docs/DEVELOPMENT.md`.**
   Specifically: runtime Wine must export `winemac.drv` public
   symbols. A one-line nm check makes the diagnosis trivial:
   ```
   nm -g <wine>/lib/wine/x86_64-unix/winemac.so | awk '$2=="T"'
   ```
   Zero hits = Wine will not work at runtime for this project.

### Environment

| | |
| --- | --- |
| macOS | Tahoe 26.4 (25E246) |
| Mac | MacBook Pro 13" M1 (2020) |
| Wine runtime | Homebrew `wine-stable` 11.0 (Gcenx cask) |
| Wine build-tree | 3Shain `v8.16-3shain/wine.tar.gz` |
| DXMT | master @ `43a16e9`, same symptom on `v0.74` |
| Title reproducing | 幻獣大農場 (32-bit Unity 6000) |

Full evidence (nm output of both Wine builds, DXMT stderr capture,
Unity Player.log) lives in
<https://github.com/notpop/steam-on-m1-wine/tree/main/docs/evidence>.
