# DXMT nightly experiment (v0.3)

2026-04-23 に行った DXMT ナイトリー差し替えテストの記録。

## きっかけ

v0.2 段階で Unity 6000 製 2D 放置ゲーム (幻獣大農場) を起動すると、

- `D3D11CreateDevice` まで成功 (`Renderer: Apple M1`)
- Unity の `[Physics::Module]`、`Input initialized` までログが進む
- macOS 側に `MonsterFarm` ウィンドウが登録される
- しかしウィンドウは **3840×2160 (Retina の raw pixel) のまま透明** で、Present() のフレームが CAMetalLayer に届かない
- MonsterFarm プロセスは **CPU 100% の busy loop**

この症状が DXMT v0.74 の既知のバグなのか、Wine 11.0 + macOS Tahoe 26 固有の相性問題なのかを切り分けるため、DXMT master の最新 nightly (GitHub Actions artifact) を取り込んで差し替えた。

## 投入した nightly

- **Artifact**: `dxmt-43a16e9223b5c43ceb08efd741036d74a9cb843d`
  (= commit `43a16e9`, 2026-04-22 ビルド)
- **v0.74 (`cc59982`) 以降の主な追加**:
  - `40fae03` — `fix(util): wsi: set present rect for d3dkmt` (PR [#139](https://github.com/3Shain/dxmt/pull/139))
    フルスクリーン切替時に `D3DKMT_ESCAPE_SET_PRESENT_RECT_WINE` (escape 0x80000001) で winemetal に矩形を伝える
  - `719d247` — `chore(d3d11): defatalize and stub some methods of IDXGISwapChain1/2/3`
    Unity 系のモダン swapchain 呼び出しで assert crash していた箇所を warn へ降格

### ファイル差分
| パス | v0.74 | nightly | 差 |
| --- | --- | --- | --- |
| `winemetal.so` | md5 `38a5aff3…` | md5 `695c1c37…` | 別ビルド |
| `x86_64-windows/d3d11.dll` | 5,218,440 B | **5,350,897 B** | +132 KB |
| `i386-windows/d3d11.dll` | 5,596,248 B | **5,689,841 B** | +93 KB |

## 結果

nightly に差し替えて同じ手順 (Steam → 幻獣大農場 → プレイ) を踏んだところ:

| 観察点 | v0.74 | nightly |
| --- | --- | --- |
| ウィンドウ登録 | あり (3840×2160 透明) | あり (3840×2160 透明) |
| `Player.log` 最終行 | `Input initialized` | `Input initialized` |
| プロセス CPU | **101%** (busy loop) | **0.0%** (idle wait) |
| `<proc>_d3d11.log` 出力 | ほぼ無し | サイズ 0 (ファイルは作られるが空) |

つまり:

- **画面に何も出ない症状は解消していない**
- ただし **CPU の使い方が 100% → 0% に変わった** = nightly の `40fae03` / `719d247` のどちらかが **busy loop に入る前のコードパスを通すようにした** = どこかで待機状態に入っている

待機状態に入っているということは、DXMT 自身が `Present()` のループを回し続けているのではなく、**Unity が D3D11 呼び出しそのものを止めている (→ おそらく swapchain 生成直後の Metal drawable 取得で block)** の可能性が高い。

## 判定

- upstream DXMT の master HEAD 時点で **完全な修正は入っていない**
- 完全一致する open Issue / PR も見つかっていない
- swapchain → CAMetalLayer の lifecycle の macOS Tahoe 固有の違い (AppKit 内部変更) に踏み込まないと直らない見込み
- 本プロジェクト側では **v0.3 として nightly 検証の記録を残すのみ** にとどめる

本格的なパッチは fork ルート (別ブランチで進行中) に移行する。

## 再現用スクリプト

- `scripts/experimental/04b-install-dxmt-nightly.sh` — gh CLI で master の最新 artifact を取得して DLL を差し替え。初回実行時は v0.74 を `vendor/dxmt-v074-backup/` に退避する
- `scripts/experimental/04b-revert-to-dxmt-v0.74.sh` — 退避した v0.74 を戻す
- `scripts/experimental/run-with-dxmt-debug.sh` — `DXMT_LOG_LEVEL=debug DXMT_LOG_PATH=/tmp/dxmt-logs` を設定して Steam を起動する。ゲームが落ちた後に `/tmp/dxmt-logs/<ProcessName>_d3d11.log` などが残る

**Note on `DXMT_LOG_LEVEL`**: ソース (`src/util/log/log.hpp`) と `docs/DEVELOPMENT.md` が
一致しており、値は **文字列**: `none` / `error` / `warn` / `info` / `debug` / `trace`。
数値 (`3` など) を渡すと意図と違うレベルで処理される可能性があるので、必ず文字列で渡すこと。

## 次フェーズ: fork して診断ログを注入する

本実験のあと、upstream に PR が立っていないと判断して fork を切った:

- **fork**: <https://github.com/notpop/dxmt>
- **branch**: [`debug/present-path-tracing`](https://github.com/notpop/dxmt/tree/debug/present-path-tracing)
- **commit**: `b8ebec5` "debug: trace swapchain Present() and macdrv Metal view handover"

追加した trace は 3 ヶ所、すべて加算のみで挙動は変えない:

| ファイル | 位置 | 目的 |
| --- | --- | --- |
| `src/winemetal/unix/winemetal_unix.c` | `_CreateMetalViewFromHWND` | dlsym したシンボル値と、成功時の `client_cocoa_view` / `macdrv_metal_view` / `macdrv_metal_layer` を `fprintf(stderr)` で出力。`DXMT_DEBUG_METAL_VIEW=1` で有効化 |
| `src/d3d11/d3d11_swapchain.cpp` | `ApplyLayerProps` | `desc_.Width/Height × scale_factor` を DEBUG ログ (Retina 二重適用疑惑の検証) |
| `src/d3d11/d3d11_swapchain.cpp` | `Present1` | 各呼び出しの `SyncInterval` / `PresentFlags` / `window_minimized` / `desc_.Width/Height` / `SwapEffect` / `HRESULT` を DEBUG ログ。`DXGI_STATUS_OCCLUDED` による早期 return を見落とさないため |

### ビルド前提 (別日に実行)

DXMT の `docs/DEVELOPMENT.md` が "not for beginners" と明記するほどの重い前提が必要:

- **LLVM 15** (正確なメジャーバージョン指定、Homebrew の `llvm@15` で可)
- **mingw-w64** (x86_64 + i686、Homebrew `mingw-w64` 既済)
- **Wine 8+ のビルドディレクトリ** (Gcenx cask のバイナリには include が付属しないので、Wine 11 を `git clone && configure && make` で自前ビルドが必要。数時間コース)
- **Xcode 16+**, Meson 1.3+, Ninja

### ビルド準備で実際に判明したこと (2026-04-23)

| 要素 | どう調達したか |
| --- | --- |
| Meson / Ninja / CMake | Homebrew `brew install meson ninja cmake` |
| mingw-w64 (64+32bit) | すでに v0.1 時点でインストール済み (`brew install mingw-w64`) |
| bison / flex | `brew install bison flex` |
| Xcode Metal toolchain | `xcodebuild -downloadComponent MetalToolchain` (688 MB) |
| Wine のヘッダ + static libs + `winebuild` | **DXMT 作者 3Shain が配布する専用 tarball** を使う: `https://github.com/3Shain/wine/releases/download/v8.16-3shain/wine.tar.gz` (230 MB)。これが DXMT の CI (`.github/workflows/ci.yml`) でも使われており、`libwinecrt0.a` / `libntdll.a` / `libdbghelp.a` / `bin/winebuild` / `lib/wine/x86_64-unix/winemac.so` / 同 `ntdll.so` を全て含む。Wine 本家をソースから `./configure && make` する必要はない |
| LLVM 15 (x86_64 cross) | Homebrew の `llvm@15` は arm64 ネイティブなので cross link で x86_64 symbol が解決できず失敗する。**DXMT `docs/DEVELOPMENT.md` 通り CMake で `toolchains/llvm/` に x86_64 LLVM 15.0.7 を自前ビルド** する必要あり。M1 で 15–30 分コース。`LLVM_TARGETS_TO_BUILD=""` と `LLVM_BUILD_TOOLS=Off` で最小化済み |

### ビルド後の差し替え

`scripts/experimental/07-build-dxmt-from-fork.sh` が上記すべての前提下で一発実行する:

1. `$DXMT_SRC`  (default `~/dev/dxmt`) でサブモジュール初期化
2. `meson setup build --cross-file build-win64.txt -Dnative_llvm_path=$DXMT_SRC/toolchains/llvm -Dwine_install_path=$DXMT_SRC/toolchains/wine`
3. `meson compile -C build`
4. `build32` で同じことを 32-bit 側
5. 生成 DLL / `winemetal.so` を `scripts/04-install-dxmt.sh` と同じ配置先に手でコピー

実行後の動作確認:

1. `DXMT_DEBUG_METAL_VIEW=1 DXMT_LOG_LEVEL=debug scripts/experimental/run-with-dxmt-debug.sh`
2. Steam UI から幻獣大農場をプレイ
3. `/tmp/dxmt-logs/MonsterFarm_d3d11.log` と macOS 側 stderr (`/var/folders/.../steam-on-m1-wine.log`) に吐かれた trace を読む

### 期待される診断

trace を見ると以下のどれが起きているかを切り分けられるはず:

- `Present1` が呼ばれず、`ApplyLayerProps` 段階で `desc_.Width × scale` が異常値 → scale_factor 二重適用の検証
- `Present1` は呼ばれているが `hr == DXGI_STATUS_OCCLUDED` で早期 return → Window minimized 誤判定
- `CreateMetalViewFromHWND` の `client_cocoa_view` か `macdrv_metal_view` が NULL → Wine 11 の macdrv 側 regression
- どの log も沈黙 → Unity が D3D11 ではなく別 API (Metal direct? OpenGL?) を叩きに行っている

切り分けが付けば、upstream 3Shain/dxmt にも具体的な症状を添えて issue を立てられる。
