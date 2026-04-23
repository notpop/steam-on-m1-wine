# Draft: GitHub issue for 3Shain/dxmt

Target: <https://github.com/3Shain/dxmt/issues/new>

---

## Title

macOS/Wine 11: `_CreateMetalViewFromHWND` reads a
never-populated struct field, and a naive `OnMainThread` wrap
deadlocks

---

## Summary

The "transparent window" symptom on Wine 11 decomposes into two
DXMT-side bugs, both independent of the well-known
`-fvisibility=hidden` issue. This issue proposes a fix implemented
on fork branch
[notpop/dxmt@debug/present-path-tracing](https://github.com/notpop/dxmt/tree/debug/present-path-tracing),
which adds a ~150-line patch to
`src/winemetal/unix/winemetal_unix.c` on top of upstream `43a16e9`.
Happy to submit as a PR once the design is agreed.

---

## Bug 1: `win_data->client_cocoa_view` is always NULL at swap-chain creation time

**File:** `src/winemetal/unix/winemetal_unix.c`,
`_CreateMetalViewFromHWND` (upstream L1575-1610).

The unix-side calls `get_win_data(hwnd)` and then reads
`win_data->client_cocoa_view`. On current Wine 11 this field is
always NULL for two independent reasons:

1. The struct field was renamed to `client_view`
   (`dlls/winemac.drv/macdrv.h:177-192`), so the offset DXMT reads
   is stale after ABI drift between 3Shain's v8.16 fork and
   upstream Wine 11.
2. Even if you rename the field, it is populated lazily, only
   inside the GDI present path
   (`macdrv_client_surface_present()` in
   `dlls/winemac.drv/window.c:1131-1135`). At `IDXGISwapChain`
   creation time no frame has been presented yet, so the field is
   NULL for every swap-chain the game creates.

Net effect: the happy path in `_CreateMetalViewFromHWND` always
passes a NULL `NSView*` to `macdrv_view_create_metal_view`, the
window stays transparent, and no error is logged.

**Proposed fix:** drop the internal struct dereferencing entirely
and use the stable public accessor
`macdrv_get_cocoa_window(HWND, BOOL)` (exported from `macdrv.h`
since Wine 8) plus Cocoa's `[NSWindow contentView]`. This bypasses
both problems: no ABI drift, no lazy-population race. The
`contentView` exists as soon as `macdrv_create_cocoa_window`
finishes, which is synchronous during `CreateWindowEx`.

---

## Bug 2: `OnMainThread` is not re-entrant

The natural fix above requires `[NSWindow contentView]` to be read
on the AppKit main thread. A reasonable next attempt wraps the
whole Metal-view setup in `OnMainThread(^{...})`. That deadlocks
the game on Wine 11.

The deadlock is two layers deep in macdrv:

- `dlls/winemac.drv/cocoa_window.m:3941, 3954, 3966` --
  `macdrv_view_create_metal_view`, `macdrv_view_get_metal_layer`,
  and `macdrv_view_release_metal_view` each wrap their own body in
  `OnMainThread(^{...})` internally.
- `dlls/winemac.drv/cocoa_event.m:489` -- `OnMainThread` is
  implemented as `OnMainThreadAsync(^{ block(); finished=TRUE;
  signal; })` plus a blocking wait. Calling it from the main
  thread causes the main thread to wait on a semaphore that the
  main thread itself must release. It is not re-entrant.

So wrapping the macdrv helpers in DXMT's own `OnMainThread` is a
nested main-thread dispatch: the outer wait suspends the main
thread and the inner block never runs.

**Proposed fix:** do not wrap the macdrv helpers. Call
`macdrv_view_create_metal_view`, `_get_metal_layer`, and
`_release_metal_view` directly from the Wine NtUser caller thread
and let each helper dispatch to the main thread by itself. The
only Cocoa call DXMT still makes on its own is
`[NSWindow contentView]`, which has no macdrv wrapper, so that
single lookup is dispatched through `OnMainThread` (with
`pthread_main_np()` + `dispatch_sync` as fallbacks for Wine builds
where the symbol is hidden).

---

## Verification

Reference setup: Apple Silicon M1 / macOS Tahoe 26.4 / Wine 11.0
rebuilt with `CFLAGS=-fvisibility=default` so all 200 winemac.drv
public symbols are exported / DXMT fork branch applied.

The stderr trace at `DXMT_DEBUG_METAL_VIEW=1` now reads:

```
[dxmt/winemetal] CreateMetalViewFromHWND: done hwnd=0x401a6
  cocoa_window=0x... content_view=0x... view=0x... layer=0x...
```

All four pointers non-zero. `Present1` returns `hr=0x0` for every
frame. The 32-bit Unity 6000 game 幻獣大農場 (Steam AppID 3659410)
renders inside a normal NSWindow and plays end-to-end.

---

## Why this matters

The transparent-window bug is three stacked issues, of which only
the first (Wine `-fvisibility=hidden`) has been reported publicly
before. The other two are pure DXMT-side, so rebuilding Wine with
`-fvisibility=default` is necessary but not sufficient. Fixing
Bug 1 and Bug 2 in DXMT closes the gap without needing Wine-side
patches for the common case.

---

## Open questions for the maintainer

- Is the "public accessor + `[NSWindow contentView]`" approach
  acceptable, or would you prefer to add a new macdrv helper (e.g.
  `macdrv_view_create_metal_view_for_hwnd`) and push it into Wine?
  The latter is cleaner long-term but requires coordinating two
  repos.
- The `DXMT_DEBUG_METAL_VIEW` env-gated trace in the fork patch is
  diagnostic-grade; happy to drop it or keep it behind the gate
  per your preference.
- Any interest in an unconditional `ERR(...)` on the "all macdrv
  symbols NULL" path? That would have saved the debugging time this
  took; gated or unconditional, your call.

---

## Environment

| | |
| --- | --- |
| macOS | Tahoe 26.4 (25E246) |
| Mac | MacBook Pro 13" M1 (2020), 16 GB |
| Wine | 11.0 stable, rebuilt with `CFLAGS=-fvisibility=default` |
| DXMT | master `43a16e9` + fork branch `notpop/dxmt@debug/present-path-tracing` |
| Title reproducing | 幻獣大農場 (AppID 3659410, 32-bit Unity 6000) |
| CEF | Steam's cef.win64 @ 126.0.6478.183, `--disable-gpu --single-process` via custom steamwebhelper wrapper |

Full reproduction and evidence:
<https://github.com/notpop/steam-on-m1-wine>
