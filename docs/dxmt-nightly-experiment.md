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
- `scripts/experimental/run-with-dxmt-debug.sh` — `DXMT_LOG_LEVEL=3 DXMT_LOG_PATH=/tmp/dxmt-logs` を設定して Steam を起動する。ゲームが落ちた後に `/tmp/dxmt-logs/<ProcessName>_d3d11.log` などが残る
