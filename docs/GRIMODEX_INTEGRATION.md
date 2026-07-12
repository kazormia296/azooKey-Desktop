# Grimodex integration guide

この文書は Grimodex IME snapshot V1 の macOS consumer 実装、運用設定、CI、
release に必要な手順をまとめます。

## データフロー

Grimodex が user-local directory へ snapshot を atomic publish し、process-wide の
`ConverterServer` runtime が directory changes を監視します。読み込みに成功した
snapshot は session ごとに scope 判定され、動的辞書と Zenzai v3 条件へ反映されます。
renderer、IME、ConverterServer の間で project data を network 送信しません。

通常の root は次です。

```text
~/Library/Application Support/com.miyakey.grimodex/ime/
├── state.json
├── projects/
│   └── <project_id>.json
└── consumers/
    └── azookey-grimodex.json
```

test と process E2E では `GRIMODEX_IME_ROOT` で root を一時 directory へ変更できます。

### `state.json`

`format_version: 1`、`active_project_id`、`updated_at` を持ちます。
`active_project_id` が `null` の場合、project integration は inactive です。consumer は
state を project file の前後で二度読みし、読み込み中に active project が変わった場合は
古い payload を publish しません。

### `projects/<project_id>.json`

`format_version: 1`、project ID/name、generation timestamp、辞書 entries、任意の
`profile` と `zenzai_context` を持ちます。辞書 category / priority は
AzooKeyKanaKanjiConverter の dynamic dictionary entry へ決定的に map され、重複は
consumer 側で除去されます。topic/style/preference は converter の条件長へ bounded map
されます。

consumer は state 64 KiB、project 16 MiB、entry 20,000 件などの protocol limits を
読み込み前後で検証します。invalid / oversized / path traversal 相当の入力は適用せず
fail closed になります。atomic replace 競合に相当する retryable failure は一度再試行し、
その間は直前の有効 payload を保持します。

### `consumers/azookey-grimodex.json`

canonical consumer ID は `azookey-grimodex`、表示名は `Grimodex IME for macOS` です。
ConverterServer 起動時に `0600` の JSON handshake を atomic write し、15 分ごとに
`last_seen` を更新します。parent directories は `0700` へ補正します。

registrar の明示的な unregister と uninstall script は、この consumer file を削除します。
Grimodex が管理する state / project data は削除しません。

## scope と secure input

設定 key は
`com.miyakey.grimodex.inputmethod.preference.grimodexScope` です。

| UI | wire value | 動作 |
| --- | --- | --- |
| 無効 | `off` | project payload を適用しない |
| Grimodexのみ | `grimodexOnly` | bundle ID が厳密に `com.miyakey.grimodex` の場合だけ適用（default） |
| すべてのアプリ | `allApplications` | secure input 以外の app へ適用 |

bundle ID が不明、表記揺れ、別 app の場合、`grimodexOnly` は fail closed です。
Secure Input を検出した場合は mode に関係なく即時 revoke し、project dictionary、
Zenzai 条件、learning を無効化します。IME client の周辺テキストも取得しません。

## snapshot generation

1 回の composition 中は開始時の Grimodex revision を pin します。directory watcher が
新 generation を publish しても、変換候補の途中では切り替えません。commit、cancel、
deactivate などの composition boundary で pending generation を適用します。
Secure Input への遷移だけは boundary を待たずに revoke します。

## network-zero と sandbox

Grimodex integration は上記 local files と local XPC / Mach service だけを利用します。
`azooKeyMac/azooKeyMac.entitlements` と `azooKeyMac/ConverterServer.entitlements` は
`com.apple.security.network.client` を持ちません。ConverterServer は app sandbox を
有効にし、Grimodex IME directory への限定された home-relative file access と
app group / Mach service entitlement を使用します。
Developer ID release は provisioning profile を必要としない macOS 形式
`<APPLE_TEAM_ID>.com.miyakey.grimodex.inputmethod` を app/helper の両方へ署名前に設定し、
署名済み helper が shared container を解決できることを workflow 内で実行確認します。

## ローカル検証

依存 submodule と LFS object を取得してから実行します。

```bash
git submodule update --init --recursive
git lfs install --local
git submodule foreach --recursive 'git lfs pull'
```

Core protocol / scope / generation tests:

```bash
swift test --package-path Core
```

実際の ConverterServer build:

```bash
swift build --package-path Core --configuration release --product ConverterServer
swift build --package-path Core --configuration release --show-bin-path
```

Grimodex checkout と組み合わせる process E2E:

```bash
server_bin="$(swift build --package-path Core --configuration release --show-bin-path)/ConverterServer"
GRIMODEX_MACOS_IME_SERVER="$server_bin" \
  cargo test \
  --manifest-path /path/to/Grimodex/src-tauri/Cargo.toml \
  -p grimodex-db \
  --test macos_ime_server_e2e \
  -- --ignored --nocapture
```

unsigned app と Xcode tests:

```bash
xcodebuild \
  -project azooKeyMac.xcodeproj \
  -scheme azooKeyMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  -only-testing:azooKeyMacTests \
  test
```

unsigned Release app:

```bash
xcodebuild \
  -project azooKeyMac.xcodeproj \
  -scheme azooKeyMac \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  build
```

unsigned package contract:

```bash
Tools/build_grimodex_pkg.sh \
  --app build/DerivedData/Build/Products/Release/azooKeyMac.app \
  --output build/package \
  --version 0.1.0
```

GitHub-hosted CI を手動で起動・監視する場合:

```bash
gh workflow run grimodex-phase5.yml --ref <branch>
gh run list --workflow grimodex-phase5.yml --limit 1
gh run watch <run-id> --exit-status
```

## CI の責務境界

`.github/workflows/grimodex-phase5.yml` の required checks は GitHub-hosted
`macos-15` runner で次を検証します。

- Swift Core contracts
- real `ConverterServer` process が handshake を登録し、Grimodex reader が macOS
  capabilities を認識する writer-to-reader E2E
- 初期 snapshot の辞書/Zenzai mapping と atomic project replace 後の watcher reload
- Xcode unit tests と unsigned Release app build
- branded bundle ID、offline entitlements、sandboxed helper
- `.pkg` layout、embedded ConverterServer、postinstall LaunchAgent

この E2E は mock server ではなく実 process を起動しますが、InputMethodKit の
入力ソース選択 UI は通りません。hosted runner には対話可能な login/input-source 状態が
保証されないため、入力ソース追加から任意 app への実 typing までを含む OS E2E は
self-hosted の対話可能な実機 Mac が用意された場合だけ実行できます。

CI は Grimodex contract checkout を
`GRIMODEX_CONTRACT_COMMIT` の immutable commit へ pin します。protocol contract を更新する
場合は両 repository の tests を先に更新し、この SHA を意図的に変更してください。

## release workflow

`.github/workflows/grimodex-release.yml` は `v*` tag または手動
`workflow_dispatch` で、app と nested ConverterServer の Developer ID signing、
notarization/stapling、Installer signing、Gatekeeper 検証、SHA-256 artifact 作成を行います。
job は `release` environment を使用するため、production secrets と required reviewer を
この environment に設定してください。unsigned build と dependency plugin 実行は signing
credentials を一時 keychain へ読み込む前に完了します。

repository または environment secrets に次を登録します。

| secret | 内容 |
| --- | --- |
| `APPLE_CERTIFICATE` | Developer ID Application `.p12` の base64 |
| `APPLE_CERTIFICATE_PASSWORD` | Application `.p12` password |
| `APPLE_INSTALLER_CERTIFICATE` | Developer ID Installer `.p12` の base64 |
| `APPLE_INSTALLER_CERTIFICATE_PASSWORD` | Installer `.p12` password |
| `KEYCHAIN_PASSWORD` | CI temporary keychain 用の十分に強い password |
| `APPLE_API_KEY_BASE64` | App Store Connect API private key (`AuthKey_*.p8`) の base64 |
| `APPLE_API_KEY` | App Store Connect API key ID |
| `APPLE_API_ISSUER` | App Store Connect issuer ID |
| `APPLE_TEAM_ID` | Developer ID certificate と一致する 10 文字の Team ID |

certificate や private key を repository file、workflow log、artifact に置かないでください。
workflow は一時 keychain と key files を `always()` cleanup step で削除します。

手動 release では leading `v` を付けない version（例: `0.1.0`）を入力します。tag release
では `v0.1.0` のような tag 名から version を解決します。生成物は
`grimodex-ime-macos-<version>.pkg`、uninstall script とそれぞれの `.sha256` です。

```bash
gh workflow run grimodex-release.yml --ref <branch> -f version=0.1.0
gh run list --workflow grimodex-release.yml --limit 1
gh run watch <run-id> --exit-status
```

## package layout と削除対象

`Tools/build_grimodex_pkg.sh` は app を `/Library/Input Methods/azooKeyMac.app` へ配置し、
postinstall が次を作成・起動します。

```text
/Library/LaunchAgents/com.miyakey.grimodex.inputmethod.ConverterServer.plist
```

これは fork 単独配布用の管理者承認を伴う system pkg です。将来 Grimodex 本体へ
同梱する管理者不要の `~/Library/Input Methods/` 配置は、Grimodex の初回起動
assistant が別経路で担います。postinstall は同じ app path を使っていた上流版からの
移行時に、旧 `dev.ensan.inputmethod.azooKeyMac.ConverterServer` LaunchAgent を停止・
削除して二重 helper を防ぎます。

uninstall script は app、system/user LaunchAgent、package receipt と次の consumer record を
削除します。

```text
~/Library/Application Support/com.miyakey.grimodex/ime/consumers/azookey-grimodex.json
```

完全な uninstall command は repository root の [README](../README.md#アンインストール) を
参照してください。主導線は次です。

```bash
sudo Tools/uninstall_grimodex_ime.sh <macOS-user>
```

Grimodex が所有する `state.json` と `projects/` は削除対象に含めません。
