# Draft: upstream issue for 3Shain/dxmt

File this at <https://github.com/3Shain/dxmt/issues/new> when ready.
Title and body below are intentionally written in English so they are
useful to the upstream maintainer and other users.

---

## Title

Silent failure when `winemac.so` exports no public symbols (transparent window on Gcenx Wine 11.0)

## Body

### Summary

On an M1 MacBook Pro running macOS Tahoe 26.4 with Homebrew's
`wine-stable` 11.0 (the Gcenx cask that most free-path docs point to),
every DirectX 11 title runs through DXMT to a transparent window. The
failure is silent — no `ERR(…)` / `WARN(…)` lines appear, so it looks
like #141 but actually has a different root cause.

The root cause is that `winemac.so` in this Wine build contains **no
exported public symbols at all**. DXMT's `_CreateMetalViewFromHWND`
in `src/winemetal/unix/winemetal_unix.c` probes
`dlsym(RTLD_DEFAULT, "macdrv_functions")`, then
`dlsym(RTLD_DEFAULT, "get_win_data")`, etc., and all four probes
return `NULL`. The following `if (…)` block is skipped and
`STATUS_SUCCESS` is returned with `ret_view = ret_layer = 0`. The
caller treats that as success, so the eventual Metal surface never
attaches to the `NSView`.

### Reproduction

```bash
# Runtime Wine (offending, DXMT fails)
/Applications/Wine\ Stable.app/Contents/Resources/wine/lib/wine/x86_64-unix/winemac.so
# → nm -g |awk '$2=="T"' gives 0 results

# Build-time Wine recommended by docs/DEVELOPMENT.md (OK)
toolchains/wine/lib/wine/x86_64-unix/winemac.so      # from v8.16-3shain/wine.tar.gz
# → nm -g |awk '$2=="T"' gives 17 results, including
#   _get_win_data, _macdrv_view_create_metal_view,
#   _macdrv_view_get_metal_layer, _macdrv_view_release_metal_view,
#   _release_win_data
```

Steam + any DX11 title launched from it on the first Wine hits the
transparent-window symptom. The DXMT logs stay empty because nothing
in the current `_CreateMetalViewFromHWND` calls `ERR`.

### Instrumentation I used locally

I added a `DXMT_DEBUG_METAL_VIEW=1` stderr trace right before and
after the `dlsym` block (branch
`https://github.com/notpop/dxmt/tree/debug/present-path-tracing`).
Sample output on the Gcenx runtime:

```
[dxmt/winemetal] CreateMetalViewFromHWND: hwnd=0x90190
  macdrv_functions=0x0 get_win_data=0x0 release_win_data=0x0
  create_metal_view=0x0 get_metal_layer=0x0
[dxmt/winemetal] CreateMetalViewFromHWND: one of the macdrv function
  pointers is NULL, silently returning empty view/layer
```

### Proposed upstream changes

Happy to send PRs if either is welcome:

1. Replace the silent fall-through with an unconditional `ERR(…)` /
   `fprintf(stderr, …)` covering the "all four probes returned NULL"
   case. That alone would have cut this investigation down to a few
   seconds instead of most of a day.

2. Document in `docs/DEVELOPMENT.md` and/or `README.md` that the
   **runtime** Wine must export these `winemac.drv` symbols. Point
   users at `v8.16-3shain/wine.tar.gz` (or an equivalent build) as
   the supported Wine runtime, and mention that Homebrew
   `wine-stable` / similar `-fvisibility=hidden` builds will not
   work — with a short `nm -g | awk '$2=="T"'` diagnostic recipe.

### Environment

| | |
| --- | --- |
| Mac | MacBook Pro 13" M1 (2020), 16 GB |
| macOS | Tahoe 26.4 (Build 25E246) |
| Homebrew | 5.1.x, prefix `/opt/homebrew` |
| Wine | Gcenx `wine-stable` 11.0 (cask) |
| DXMT | master HEAD @ `43a16e9` (confirmed) and v0.74 (same symptom) |
| Title | 幻獣大農場 (MonsterFarm.exe, 32-bit Unity 6000) |

Raw evidence files (`nm` output of both `winemac.so`, stderr capture,
`Player.log`) are in
`https://github.com/notpop/steam-on-m1-wine/tree/main/docs/evidence/`.

### Not an accurate duplicate of #141

#141's symptom is "Steam CEF shows a black window" and its proximate
cause is DXMT's cross-process swapchain limitation. With
`--in-process-gpu --single-process` that problem goes away; what we
have left is the underlying `winemac.so` visibility issue described
above. A standalone DirectX 11 title (non-CEF) reproduces this one.
