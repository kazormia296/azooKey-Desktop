# Grimodex IME for macOS

Grimodex のプロジェクト語彙を macOS の日本語入力で利用するための、
[azooKey on macOS](https://github.com/azooKey/azooKey-Desktop) の統合フォークです。
azooKey のかな漢字変換と Zenzai を基盤に、Grimodex がローカルへ公開する
IME snapshot V1 を読み込みます。

このフォークは Grimodex 統合向けの実験版です。入力方式は OS 全体に影響するため、
重要な文書で使う前にバックアップを取り、問題がある場合はアンインストールしてください。

## Grimodex 統合の特徴

- `state.json` と `projects/<project_id>.json` から IME snapshot V1 を厳格な上限付きで読み込む
- プロジェクト語彙を動的辞書へ、topic/style/preference を Zenzai v3 の条件へ反映する
- デフォルトでは bundle ID が `com.miyakey.grimodex` のアプリだけにプロジェクト情報を適用する
- 変換中は同じ snapshot generation を固定し、次の変換境界で更新する
- Secure Input を検出したらプロジェクト情報を即時破棄し、周辺テキストの取得と学習を停止する
- Grimodex 連携はファイルベースの network-zero 構成で、IME と ConverterServer の
  entitlements にネットワーククライアント権限を持たせない

プロトコル、設定、検証方法の詳細は
[Grimodex integration guide](docs/GRIMODEX_INTEGRATION.md) を参照してください。

## 動作環境

- macOS 15 を基準に CI 検証
- Grimodex の macOS 版

上流プロジェクトでは macOS 14 / 15 / 26 が対象ですが、このフォークの完全な
OS 入力ソース E2E は対話可能な実機が必要です。CI の保証範囲は
[テストと CI](#テストと-ci)を参照してください。

## `.pkg` からインストール

1. このフォークの release workflow artifact から、署名・notarize 済みの
   `grimodex-ime-macos-<version>.pkg` と checksum を取得します。
2. `.pkg` を開き、画面の案内に従ってインストールします。
3. macOS からログアウトして再ログインします。
4. 「システム設定」→「キーボード」→「テキスト入力」→「編集」→「+」→
   「日本語」で `azooKeyMac` を追加します。
5. メニューバーの入力メニューから `azooKeyMac` を選択します。
6. Grimodex を起動し、利用するプロジェクトを開きます。

GitHub Actions の `Unsigned app and pkg contract` artifact は構造検証用であり、
日常利用向けの署名済み配布物ではありません。

同じ system path に上流 azooKey がある場合、installer は bundle ID が
`dev.ensan.inputmethod.azooKeyMac` と一致することを確認し、Installer の atomic upgrade で
Grimodex 版へ移行します。
別製品は上書きせず、user-local の上流 azooKey とその LaunchAgent も削除しません。

## アンインストール

最初に別の入力ソースへ切り替え、システム設定の入力ソース一覧から
`azooKeyMac` を削除します。その後、この repository の root で、対象となる
macOS user 名を指定して実行します。

```bash
sudo Tools/uninstall_grimodex_ime.sh <macOS-user>
```

この script は ConverterServer の system/user LaunchAgent を停止・削除し、
`/Library/Input Methods/azooKeyMac.app`、package receipt、対象 user の
`~/Library/Application Support/com.miyakey.grimodex/ime/consumers/azookey-grimodex.json`
を削除します。最後に macOS からログアウトして再ログインします。Grimodex の
`state.json` やプロジェクト snapshot は削除しません。

## 設定

IME の設定画面にある「Grimodex連携」→「プロジェクト語彙を使う範囲」で選択します。

- `無効`: プロジェクト情報を使わない
- `Grimodexのみ`: `com.miyakey.grimodex` でだけ使う（デフォルト）
- `すべてのアプリ`: Secure Input 以外のアプリで使う

Secure Input はこの設定より常に優先されます。

## テストと CI

`.github/workflows/grimodex-phase5.yml` は GitHub-hosted macOS runner で次を実行します。

- Core の protocol / scope / generation テスト
- 実際の `ConverterServer` process と Grimodex writer の E2E
- macOS app の unsigned build と Xcode テスト
- network-zero entitlements と `.pkg` 内容の検証

hosted runner では入力ソースの手動追加、ログインセッションの切り替え、任意アプリへの
実キーストローク入力を安定して自動化できません。そのため、OS の InputMethodKit を通る
完全な typing E2E は、対話可能な実機 Mac を用意した場合だけ追加で実施します。

署名・notarize・配布 package は `.github/workflows/grimodex-release.yml` が担当します。

## 上流 azooKey の機能

- ニューラルかな漢字変換システム「Zenzai」による高精度な変換
  - プロフィールプロンプト
  - 履歴学習
  - ユーザ辞書
  - 個人最適化システム「[Tuner](https://github.com/azooKey/Tuner)」との連携
- LLM による「いい感じ変換」
- ライブ変換
- AZIK のネイティブサポート

このフォークの network-zero entitlements では、ネットワークを必要とする上流機能は
利用できない場合があります。

## 開発ガイド

### 必要な環境

- macOS 15+
- Xcode 16.3（CI）または上流が案内する Xcode 26.1+
- Git LFS（submodule のモデル重み取得に必須）
- SwiftLint

```bash
brew install git-lfs swiftlint
git lfs install
```

### クローン

submodule に zenz の gguf 重みと言語モデル（`.marisa`）が含まれます。

```bash
git lfs install
git clone https://github.com/kazormia296/azooKey-Desktop --recursive
cd azooKey-Desktop
```

既存 clone で submodule や LFS object が不足している場合は次を実行します。

```bash
git submodule update --init --recursive
git -C azooKeyMac/Resources/gguf lfs pull
git -C azooKeyMac/Resources/base_n5_lm lfs pull
```

モデルが LFS pointer のままでないことをサイズで確認できます。

```bash
ls -lh azooKeyMac/Resources/gguf/ggml-model-Q5_K_M.gguf
```

### 署名設定と開発版インストール

`azooKeyMac.xcodeproj` を Xcode で開き、azooKeyMac target の
Signing & Capabilities で利用可能な Team を設定します。現在の bundle ID を所有できない
場合は、app group、Mach service、Info.plist、entitlements、LaunchAgent を含めて
一貫した ID へ変更してください。

```bash
./install.sh
```

`install.sh` は archive を `/Library/Input Methods/azooKeyMac.app` へ配置し、
ConverterServer の LaunchAgent を登録します。必要に応じて `azooKeyMac` process を
終了するか、入力ソースを再追加してからログアウト／再ログインしてください。

主要なローカル検証 command は
[Grimodex integration guide](docs/GRIMODEX_INTEGRATION.md#ローカル検証) にまとめています。

### 開発時のトラブルシューティング

- 署名 error の場合は Team と全 identifier の整合性を確認してください。
- `Packages are not supported when using legacy build locations...` の場合は Xcode の
  build location 設定を確認してください。
- 変換精度が低い場合はモデルが Git LFS pointer のままでないか確認してください。
- Xcode 26.0 では build できない場合があります。CI と同じ Xcode 16.3、または
  Xcode 26.1 以降を利用してください。

## 上流、ライセンス、コミュニティ

このリポジトリは Miwa Keita 氏と azooKey contributors による
[azooKey on macOS](https://github.com/azooKey/azooKey-Desktop) を基にしています。
元プロジェクトは [azooKey](https://github.com/azooKey/azooKey) と
Zenzai / AzooKeyKanaKanjiConverter を利用しています。上流への質問、要望、支援は
[azooKey Discord](https://discord.gg/dY9gHuyZN5) と
[GitHub Sponsors](https://github.com/sponsors/ensan-hcl) を参照してください。

MIT License です。著作権表示と全文は [LICENSE](LICENSE) にあります。
情報処理推進機構（IPA）の
[2024年度未踏IT人材発掘・育成事業](https://www.ipa.go.jp/jinzai/mitou/it/2024/koubokekka.html)
の支援を受けた上流プロジェクトに謝意を表します。

上流 README に掲載されている関連実装:

- [fcitx5-hazkey](https://github.com/7ka-Hiira/fcitx5-hazkey) — Linux
- [azooKey-Windows](https://github.com/fkunn1326/azooKey-Windows) — Windows
- [azoo-key-skkserv](https://github.com/gitusp/azoo-key-skkserv) — SKK server / macOS GUI

参考資料:

- [InputMethodKit の日本語解説](https://mzp.hatenablog.com/entry/2017/09/17/220320)
- [Create an input method for macOS](https://www.logcg.com/en/archives/2078.html)
- [How to develop a simple input method](https://stackoverflow.com/questions/27813151/how-to-develop-a-simple-input-method-for-mac-os-x-in-swift)
- [IME 開発参考書](https://mzp.booth.pm/items/809262)
- [上流 v1.0 roadmap](https://github.com/azooKey/azooKey-Desktop/issues/181)
