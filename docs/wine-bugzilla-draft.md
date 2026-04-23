# Draft: WineHQ Bugzilla report

Target: <https://bugs.winehq.org/enter_bug.cgi?product=Wine>
(Component: `-unknown`, pick `macdrv` or `winemac.drv` if available.)

This is where the **actual fix** for the transparent-window problem
belongs. Gcenx's `homebrew-wine` README explicitly redirects Wine
bugs to Bugzilla; their role is packaging, not source changes.
DXMT's own `3Shain/wine@6197fc7` commit already shows what the
concrete source patch looks like — this bug asks upstream to take
the same fix.

---

## Title

winemac.drv: export the public Metal-view APIs so third-party layers (DXMT, dxvk-on-Metal, …) can reach them via dlsym

## Body

### Summary

Third-party Metal translation layers running on top of Wine on
macOS (DXMT, dxvk's Metal branch, experimental CrossOver patches)
need to call a small set of functions implemented in
`dlls/winemac.drv/` at runtime, most importantly:

- `get_win_data`
- `release_win_data`
- `macdrv_view_create_metal_view`
- `macdrv_view_get_metal_layer`
- `macdrv_view_release_metal_view`

The typical approach is `dlsym(RTLD_DEFAULT, "<name>")` (or
`dlopen("winemac.so", …)` then `dlsym`). With current Wine these
calls all return `NULL` because `winemac.so` is built with
`-fvisibility=hidden` (which `configure` unconditionally appends
to `EXTRACFLAGS`) and none of these functions carry a
`visibility("default")` attribute to opt out.

The **concrete effect** is that DXMT v0.74 / master silently
returns an empty view/layer from `_CreateMetalViewFromHWND`, and
every DirectX 11 title on Wine shows a transparent window. No Wine
message distinguishes this from a real graphics failure — the
symptom looks like generic "Metal/Vulkan unsupported" at first.

### Reproduction

Any x86_64 Wine build on macOS after Wine 8.x is affected. With
Homebrew's `wine-stable` 11.0 (Gcenx cask) on Apple Silicon
Tahoe 26.4:

```
$ nm -g /Applications/Wine\ Stable.app/Contents/Resources/wine/lib/wine/x86_64-unix/winemac.so \
     | awk '$2=="T"' | wc -l
0
```

vs. the already-patched 3Shain fork (`v8.16-3shain`):

```
$ nm -g toolchains/wine/lib/wine/x86_64-unix/winemac.so \
     | awk '$2=="T"' | wc -l
17
```

Full `nm` dumps, DXMT stderr trace, and Unity `Player.log` at
<https://github.com/notpop/steam-on-m1-wine/tree/main/docs/evidence>.

### Proposed fix

Take the source patch from
[3Shain/wine@6197fc7](https://github.com/3Shain/wine/commit/6197fc7)
"winemac: export essential apis" into upstream:

- Remove `DECLSPEC_HIDDEN` from (at minimum) the Metal-view
  entry points in `dlls/winemac.drv/macdrv_cocoa.h` and
  `dlls/winemac.drv/macdrv.h`.
- Add `__attribute__((visibility("default")))` (or a central
  `WINEMAC_EXPORT` macro) to those same declarations so the
  per-file visibility override wins over `configure`'s global
  `-fvisibility=hidden`.

If upstream would rather expose a minimal C interface for
out-of-tree users instead of making the internal helpers public,
the DXMT need could also be met by a tiny new header (e.g.
`include/wine/winemac.h`) that publishes the same functions under
formally committed names.

### Addendum: `CFLAGS=-fvisibility=default` works at build time, but a second issue remains

Rebuilding Wine 11.0 locally with `CFLAGS=-fvisibility=default
CXXFLAGS=-fvisibility=default` does produce a `winemac.so` with all
200 public symbols visible (vs. 0 on a stock build), so
`-fvisibility=hidden` appended by `configure` *is* overridable that
way, contrary to what I initially wrote.

However, making the symbols visible is not enough on its own. With
a freshly rebuilt Wine 11.0 + DXMT master + the 幻獣大農場
reproduction, `dlsym` finds every function and `get_win_data(hwnd)`
returns a valid struct, but `data->client_cocoa_view` is still
`NULL`:

```
[dxmt/winemetal] CreateMetalViewFromHWND: hwnd=0x3019a
  get_win_data=0x20c42de10  release_win_data=0x20c42de90
  macdrv_view_create_metal_view=0x20c40eec0
  macdrv_view_get_metal_layer=0x20c40f0e0
[dxmt/winemetal] CreateMetalViewFromHWND: hwnd=0x3019a
  win_data=0x600001a2c000  client_cocoa_view=0x0  view=0x0  layer=0x0
err:  Failed to create metal view, …
```

Looking at `dlls/winemac.drv/window.c` the `client_cocoa_view` is
assigned from Cocoa callbacks that run on the AppKit main thread
after `alloc_win_data` has returned. DXMT reads the field
synchronously from another thread and races the Cocoa side. 3Shain's
v8.16-3shain fork apparently didn't have this race; some
reorganisation of the macdrv window-lifecycle path between Wine 8
and Wine 11 introduced it.

So while **re-adding `visibility("default")` on the relevant
entry points (the 6197fc7 approach) is still valuable**, a complete
fix probably also needs either a synchronous accessor —
something like `macdrv_get_or_create_cocoa_view(hwnd)` that
guarantees the Cocoa side has finished — or a documented
requirement that callers dispatch onto the main thread before
reading the field.

### Why `configure`-level flags aren't a complete alternative

Wine's `configure.ac` appends `-fvisibility=hidden` unconditionally
when the compiler supports it:

```
  ac_cv_cflags__fvisibility_hidden=yes
  EXTRACFLAGS="$EXTRACFLAGS -fvisibility=hidden"
```

`CFLAGS=-fvisibility=default` works because gcc/clang obeys the
last `-fvisibility=` on the command line, but building Wine with
*every* symbol at default visibility is a blunt instrument — it
changes binary size and potentially the symbol-resolution
semantics of Wine's own modules. The source-level
`visibility("default")` attribute on just the macdrv entry points
is still the portable, minimally invasive path.

### Impact if fixed

- DXMT (and any future dxvk-Metal / VKD3D-Metal-on-Wine) can
  implement Metal surface handoff without shipping a patched Wine.
- Gcenx's Homebrew casks become sufficient for the full D3D11
  translation story; Mac users no longer need to juggle "build-time
  Wine" vs. "runtime Wine" as DXMT's docs currently suggest.
- Removes a whole class of "transparent window, no log" reports
  from user channels.
