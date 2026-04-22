# References

Upstream tickets, release notes and pages that shaped this project's
approach. All URLs were reachable on 2026-04-23.

## Wine / Wine for macOS

- WineHQ wiki — macOS download page
  https://wiki.winehq.org/MacOS
- Gcenx/macOS_Wine_builds — pre-built stable / devel / staging Wine for macOS
  https://github.com/Gcenx/macOS_Wine_builds
- Gcenx/homebrew-wine — Homebrew tap exposing the Gcenx builds
  https://github.com/Gcenx/homebrew-wine
- Homebrew Cask `wine-stable` (11.0_1, deprecated 2026-09-01 over Gatekeeper)
  https://github.com/Homebrew/homebrew-cask/blob/HEAD/Casks/w/wine-stable.rb

## DXMT

- Repository
  https://github.com/3Shain/dxmt
- Installation guide for geeks (official prefix layout)
  https://github.com/3Shain/dxmt/wiki/DXMT-Installation-Guide-for-Geeks
- Release `v0.74` (2026-03-10, the version this project pins)
  https://github.com/3Shain/dxmt/releases/tag/v0.74
- **Issue #141** — Steam CEF black-window problem and the in-process-gpu
  workaround (the single most important page for this project)
  https://github.com/3Shain/dxmt/issues/141

## Chromium / CEF

- Chromium source — `network_change_notifier_win.cc` and
  `ssl_client_socket_impl.cc`, which produce the error lines we inspect
  https://source.chromium.org/chromium
- CEF command-line switches (including `--in-process-gpu`)
  https://cef-builds.spotifycdn.com/docs/stable.html

## Steam

- Steam Subscriber Agreement (client is not redistributable)
  https://store.steampowered.com/subscriber_agreement/
- Official installer on Valve's CDN
  https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe

## Winetricks

- Repository
  https://github.com/Winetricks/winetricks
- Formula on Homebrew
  https://github.com/Homebrew/homebrew-core/blob/HEAD/Formula/w/winetricks.rb

## CrossOver (for comparison, not used here)

- Current version, supported macOS matrix
  https://www.codeweavers.com/crossover
- Steam compatibility report (4/5 stars in 26.x)
  https://www.codeweavers.com/compatibility/crossover/steam
