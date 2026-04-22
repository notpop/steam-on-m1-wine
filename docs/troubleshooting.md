# Troubleshooting

Symptoms are listed with their most likely cause and the ordered fix.

## A Unity game process runs but its window is transparent (you see the desktop through it)

**Symptom.** The game appears in `Dock`, `Cmd-Tab` lists it, the macOS
window manager reports a window with the right name, but the window is
visually empty and shows whatever is underneath. `Player.log` stops
around `Input initialized` without a crash; the process sits at
100% CPU (busy rendering → submitting frames).

**Diagnosis.** The game submitted a swapchain to DXMT's
`IDXGISwapChain::Present()` and DXMT in turn asked Metal's
`CAMetalLayer` for a drawable — but on macOS Tahoe 26 the frames
never land in the on-screen layer. This is a DXMT upstream problem,
not a configuration error in this repo. Known related discussion:
<https://github.com/3Shain/dxmt/issues/141>.

**Current status.** Not fixed in DXMT v0.74. Try the nightly build
from `https://github.com/3Shain/dxmt/actions` (each green workflow
run publishes an artifact with the latest DLLs). Install manually
by unpacking the artifact over `scripts/04-install-dxmt.sh`'s
target paths.

## Unity game opens a 4K / Retina-sized window that extends off-screen

**Symptom.** The window registers at `3840x2160` (or the raw pixel
size of a Retina display) even though you passed
`-screen-width 800 -screen-height 600`. Only the top-left patch of
the game is visible.

**Diagnosis.** Wine's `winemac.drv` reports the physical Retina
resolution as the desktop size. Unity 6000 trusts that number at
launch and ignores `-screen-width` / `-screen-height` for the first
run.

**Fixes, in order.**
1. Quit the game. The resolution you pass on the Steam launch line is
   still persisted to
   `HKCU\Software\<vendor>\<title>\Screenmanager Resolution*`, so a
   second launch typically honours 800x600 / 1280x800.
2. For a persistent fix, import `scripts/assets/retina-off.reg`
   (sets `HKCU\Software\Wine\Mac Driver\RetinaMode=n`). This makes
   Wine advertise the logical 1x resolution. Some Unity builds still
   ignore the 1x number; in that case the only robust answer is a
   windowed launch option like `-screen-width 1024 -screen-height 768`
   combined with an initial quit-and-relaunch as in step 1.

## "Failed to initialize graphics / DirectX 11" at game launch

**Cause.** DXMT's 32-bit DLLs were not installed, so Wine's builtin
`syswow64\d3d11.dll` (a ~400 KB stub) handled the `D3D11CreateDevice`
call and failed. Typical for Unity titles shipped as 32-bit Windows
binaries (幻獣大農場, older Unity games).

**Fix.** Re-run `scripts/04-install-dxmt.sh`. Versions of this script
from before the v0.2 tag only populated `lib/wine/x86_64-windows/`;
the current version also copies the `i386-windows/*.dll` pieces into
Wine and drops `winemetal.dll` into the prefix's `syswow64`.

## Game hangs at `GfxDevice: creating device client` with CPU at 100%

**Cause.** Steam's `GameOverlayRenderer.dll` was injected into the
child game process and hooked `D3D11CreateDeviceAndSwapChain`.
Unchecking the in-game overlay box in Steam's game properties is
**not** sufficient — the DLL is still mapped.

**Fix.** Ensure `launch-steam.sh` exports
`gameoverlayrenderer,gameoverlayrenderer64=d` inside
`WINEDLLOVERRIDES`. This makes Wine refuse to load the overlay DLL
at all, regardless of Steam's own setting.

## The Wine virtual desktop window freezes the entire Wine session

**Cause.** All Wine windows are forced into a single container via
`HKCU\Software\Wine\Explorer\Desktop=Default`. When one Windows
program inside that container hangs the whole container becomes
unresponsive, including Steam and every game.

**Fix.**
1. Kill everything:
   `pkill -9 -f 'steam\.exe|steamwebhelper|wineserver|wine64-preloader|explorer\.exe'`
2. Remove the Desktop key:
   `wine reg delete 'HKCU\Software\Wine\Explorer' /v Desktop /f`
3. Run `wineserver -k` so Wine flushes the change.
4. Relaunch Steam normally. Each Wine program now gets its own
   independent macOS window and one hang can no longer take the
   others down.

We currently recommend running **without** the virtual desktop for
everyday use; `scripts/assets/virtual-desktop.reg` is kept in the
repo as opt-in documentation for the rare case where a game insists
on an exclusive fullscreen and you need the container to swallow it.

## Steam launches but stays stuck with a black window

**Cause.** DXMT is not installed, or its DLLs are not being picked up.

**Fix.**
1. Re-run `scripts/04-install-dxmt.sh` — a recent Homebrew upgrade of
   `wine-stable` may have wiped the DLLs from inside the `.app` bundle.
2. Verify `WINEDLLOVERRIDES` actually reaches Steam:
   ```bash
   env | grep WINEDLLOVERRIDES
   ```
   and that `scripts/launch-steam.sh` is the entry point (it exports
   the variable itself).
3. Confirm the wrapper is in place:
   ```bash
   ls -la "$HOME/.wine-steam/drive_c/Program Files (x86)/Steam/bin/cef/"cef.win*"/steamwebhelper"*
   ```
   You should see `steamwebhelper.exe` (~80 KB, ours) and
   `steamwebhelper_real.exe` (several MB, Valve's).

## Dock shows a Steam icon but no window appears

**Cause.** `-silent` mode. Triggered when a stale Chromium
`SingletonLock` file remains after a previous crash.

**Fix.**
- `scripts/launch-steam.sh` deletes these locks at the start of every
  launch. If you invoked Steam some other way, kill everything and run
  `launch-steam.sh` again:
  ```bash
  pkill -9 -f 'steam\.exe|steamwebhelper|wineserver'
  scripts/launch-steam.sh
  ```

## `wine` immediately exits with status 137

**Cause.** macOS Gatekeeper killed an unsigned / ad-hoc-signed binary.

**Fix.** Re-run `scripts/01-install-wine.sh`; it strips the
`com.apple.quarantine` xattr. You can also do it manually:
```bash
xattr -dr com.apple.quarantine "/Applications/Wine Stable.app"
```

## `wineboot` says "version mismatch 931/930"

**Cause.** A wineserver from a previous Wine version is still running.

**Fix.**
```bash
pkill -9 -f wineserver
pkill -9 -f wine64-preloader
scripts/launch-steam.sh
```

## SSL handshake failures in `cef_log.txt` (`net_error -100`, `-107`)

**Observed.** `ssl_client_socket_impl.cc: handshake failed;
returned -1, SSL error code 1, net_error -100`.

**Likely cause.** Chromium's BoringSSL runs fine in principle on Wine,
but its non-blocking socket assumptions collide with Wine's winsock on
macOS when the GPU process is alive and out-of-process. Installing
DXMT + the webhelper wrapper generally eliminates these errors
because everything ends up in a single process.

If the errors persist:
1. Confirm the host machine can reach Steam with TLS:
   ```bash
   curl -I https://client-update.steamstatic.com/
   ```
   A 200 response means the outer network is fine.
2. Ensure the CA bundle was copied into the prefix:
   ```bash
   ls -l "$HOME/.wine-steam/drive_c/windows/cacert.pem"
   ```
3. As a last resort try `WINEDLLOVERRIDES="dxgi,d3d11,d3d10core=n,b;winhttp=n,b"`
   (uses Wine's bundled WinHTTP). This is a debugging knob; it is not
   wired into `launch-steam.sh` by default.

## "Updating Steam" dialog loops forever

**Cause.** `Package/` directory corruption after an interrupted update.

**Fix.**
```bash
rm -rf "$HOME/.wine-steam/drive_c/Program Files (x86)/Steam/package/"
scripts/launch-steam.sh
```

## After a Homebrew upgrade, DXMT or wrapper seems to vanish

**Cause.** `brew upgrade --cask wine-stable` replaces the entire
`Wine Stable.app` bundle, which is where DXMT's DLLs live.

**Fix.** Re-run the installers:
```bash
scripts/01-install-wine.sh   # strips quarantine again
scripts/04-install-dxmt.sh   # reinstalls DXMT DLLs
# The wrapper sits inside the prefix, not the Wine bundle,
# so it survives Wine upgrades. But re-running 06 is cheap:
scripts/06-install-wrapper.sh
```

## Both `steamwebhelper.exe` AND `steamwebhelper_real.exe` have the same size

**Cause.** An old version of `scripts/06-install-wrapper.sh` (before
the MD5-based check) could copy the wrapper into both slots, erasing
Valve's original binary.

**Symptom.** `06-install-wrapper.sh` refuses to continue and tells you:

```
cef.winNN: BOTH steamwebhelper.exe AND steamwebhelper_real.exe
are wrapper-sized. Valve's original is gone.
Re-run scripts/03-install-steam.sh to recover.
```

**Fix.**
1. Quit Steam completely, then:
   ```bash
   pkill -9 -f 'steam\.exe|steamwebhelper|wineserver'
   ```
2. Remove the corrupted helper files from the affected directory:
   ```bash
   STEAM="$HOME/.wine-steam/drive_c/Program Files (x86)/Steam"
   rm -f "$STEAM/bin/cef/cef.winNN/steamwebhelper.exe"
   rm -f "$STEAM/bin/cef/cef.winNN/steamwebhelper_real.exe"
   ```
3. Launch Steam once **without** `-noverifyfiles` so its bootstrap
   re-extracts `bins_cef_winNN.zip.vz` from `Steam/package/`:
   ```bash
   "$HOME/.wine-steam/drive_c/Program Files (x86)/Steam/steam.exe"  # via Wine
   ```
4. Once the bootstrap dialog reports "Verification complete", quit
   Steam and rerun `scripts/06-install-wrapper.sh`.

## Still blank: enable wrapper debug log

Set `STEAMWEBHELPER_WRAPPER_DEBUG=1` in the environment Wine sees. The
wrapper writes `wrapper-debug.log` next to itself, so you can confirm
it was invoked and with what arguments:

```bash
WRAPPER_DEBUG=1 scripts/launch-steam.sh
ls -la "$HOME/.wine-steam/drive_c/Program Files (x86)/Steam/bin/cef/"cef.win*"/wrapper-debug.log"
```

(Exact plumbing of the env var through Steam's child processes depends
on Wine's environment handling. Expect to tweak `launch-steam.sh` if
you need this.)
