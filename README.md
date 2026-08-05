# eventkit-mcp

macOS の EventKit を直接叩いて、Apple の**リマインダー**と**カレンダー**を操作する MCP サーバー。

AppleScript を一切使わない。EventKit を Swift から直接呼ぶので速い（未完了リマインダー31件で 20ms、完了済み込み328件で 60ms）。

## 構成

2つのパーツに分かれている。

```
swift/   EventKit を叩く CLI バイナリ。結果を JSON で stdout に出す
ts/      MCP サーバー。上のバイナリを子プロセスとして起動し、JSON を MCP のレスポンスに変換する
```

CLI 単体でも使えるので、MCP を経由せずシェルから叩いてデバッグできる。

## 必要なもの

| | バージョン |
|---|---|
| macOS | 14 以上（`requestFullAccessToReminders` を使うため）|
| Swift | 6.0 以上 |
| Node.js | 22 以上 |

macOS 26.5.2 / Swift 6.3.1 / Node 24.14.1 で動作確認。

## ビルド

```bash
./build.sh                      # Swift CLI をビルドして bin/EventKitCLI.app を作る
cd ts && npm install && npm run build
```

`build.sh` は `bin/EventKitCLI.app` を生成する。**素の実行ファイルではなく .app バンドルなのは TCC の都合**（後述）。

## 動作確認

```bash
./bin/EventKitCLI.app/Contents/MacOS/eventkit-cli lists
```

初回実行時に権限ダイアログが出るので許可する。リマインダーとカレンダーで別々に出る。

```json
{
  "lists" : [
    { "name": "リマインダー", "id": "…", "source": "iCloud", "isDefault": true },
    { "name": "買い物リスト", "id": "…", "source": "iCloud", "isDefault": false }
  ]
}
```

## MCP クライアントへの登録

### Claude Desktop

`~/Library/Application Support/Claude/claude_desktop_config.json`

```json
{
  "mcpServers": {
    "eventkit-mcp": {
      "command": "/absolute/path/to/node",
      "args": ["/absolute/path/to/eventkit-mcp/ts/dist/index.js"]
    }
  }
}
```

**注意点が2つある。**

1. **`node` は絶対パスで書く。** Claude Desktop は MCP サーバーをログインシェル経由で起動しないため、`nodebrew` / `nvm` / `asdf` などで入れた node は `"command": "node"` では見つからない。`which node` の結果をそのまま書く。
2. **Claude Desktop を終了してから編集する。** 起動中に設定ファイルを書き換えると、アプリ終了時にメモリ上の内容で上書きされて変更が消える。

編集後は Claude Desktop を完全終了（⌘Q）して起動し直す。

### Claude Code

```bash
claude mcp add --transport stdio eventkit-mcp -- /absolute/path/to/node /absolute/path/to/eventkit-mcp/ts/dist/index.js
```

## MCP ツール

| ツール | 必須引数 | 説明 |
|---|---|---|
| `reminder_lists` | — | リマインダーのリスト一覧 |
| `reminders` | — | リマインダー取得。`list` 省略で全リスト、既定は未完了のみ |
| `search_reminders` | `query` | 名前とメモを対象に検索 |
| `create_reminder` | `title` | 作成。`list` `due` `notes` `priority` |
| `complete_reminder` | `id` | 完了にする |
| `calendars` | — | カレンダー一覧 |
| `events` | `from` `to` | 期間内のイベント |
| `search_events` | `query` | タイトル・場所・メモを対象に検索 |
| `create_event` | `title` `start` `end` | 作成。`calendar` `location` `notes` `allDay` |

**削除機能は意図的に実装していない。** 意図しない消失を避けるため。

日時の書式：

- `2026-08-10` … 終日
- `2026-08-10T15:30:00` … 時刻付き（ローカルタイムゾーン）

優先度は EventKit の仕様に従い 0〜9（`0`=なし、`1-4`=高、`5`=中、`6-9`=低）。範囲外は保存前に弾く。

## CLI サブコマンド

```bash
eventkit-cli lists
eventkit-cli reminders --list <名前> [--include-completed]
eventkit-cli reminders --all [--include-completed]
eventkit-cli search <文字列> [--list <名前>] [--include-completed]
eventkit-cli create-reminder --title <名前> [--list <名前>] [--due <日時>] [--notes <メモ>] [--priority 0-9]
eventkit-cli complete-reminder <ID>

eventkit-cli calendars
eventkit-cli events --from <日付> --to <日付> [--calendar <名前>]
eventkit-cli search-events <文字列> [--from <日付>] [--to <日付>]
eventkit-cli create-event --title <名前> --start <日時> --end <日時> [--calendar <名前>] [--location <場所>] [--notes <メモ>] [--all-day]

eventkit-cli diag            # 権限ステータスと責任プロセスを表示（トラブル時用）
```

## TCC（権限）まわりの落とし穴

ここが実装で一番苦労した部分。同じことをやる人向けに残しておく。

### 1. 素の CLI バイナリでは権限ダイアログが出ない

リンカフラグで `__TEXT,__info_plist` セクションに `NSRemindersFullAccessUsageDescription` を埋め込めば、`Bundle.main.infoDictionary` からは正しく読める。だが**それだけではダイアログが表示されない**。tccd はリクエストを受け取り「表示する」と判断する（`promptType: 1`）ところまで進むのに、画面には何も出ず、completion handler が永久に返ってこない。

素の実行ファイルはバンドルを持たないため、TCC アラートの表示先になれないのが原因。**`.app` バンドルに包むと解決する**。`build.sh` が `bin/EventKitCLI.app` を作っているのはこのため。

### 2. 責任プロセス（responsible process）に権限が帰属する

TCC はリクエストしたプロセスではなく「責任プロセス」の Info.plist を見て、ダイアログを出すか決める。ターミナルから起動した CLI は親のターミナルアプリが責任プロセスになるので、許可はターミナルに紐づく。

問題は MCP ホストから起動されたとき。ホストアプリの Info.plist に usage description が無いと、**tccd に問い合わせる前に EventKit が即 `false` を返す**。認可ステータスは `notDetermined` のままで、拒否の記録すら残らないので原因が分かりにくい。

対策として、起動時に自分自身を disclaim 付きで再 exec し、責任プロセスを自分にしている（`Disclaim.swift`）。

```swift
posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETEXEC))
responsibility_spawnattrs_setdisclaim(&attr, 1)
posix_spawn(nil, exePath, nil, &attr, &argv, &envp)
```

`diag` サブコマンドで責任プロセスが自分になっているか確認できる。

```console
$ eventkit-cli diag
{
  "pid" : "12345",
  "responsiblePID" : "12345",          ← pid と一致していれば OK
  "responsiblePath" : "…/EventKitCLI.app/Contents/MacOS/eventkit-cli",
  "reminderStatus" : "fullAccess",
  "eventStatus" : "fullAccess"
}
```

### 3. 許可は .app のパスにも紐づく

ad-hoc 署名では、TCC はバンドル識別子だけでなく**実パス**も識別子に含める。同じ場所で再ビルドする分には許可は維持されるが、**ディレクトリを移動すると `notDetermined` に戻って再許可が必要**になる。`CFBundleIdentifier` を変えた場合も同じ。

頻繁に移動するなら、`.app` を固定パスに置くよう `build.sh` を変更するとよい。Developer ID 証明書で署名すればパス非依存にできる（未実施）。

### 4. Info.plist を変えても再リンクされない

SwiftPM は `-sectcreate` に渡した Info.plist をビルド依存として追跡しない。Info.plist だけ書き換えて `swift build` してもバイナリ内は古いまま。`build.sh` は毎回バイナリを消してから再リンクしている。

## その他の実装メモ

- **日本語の正規化揺れ**：検索は `precomposedStringWithCanonicalMapping` で NFC に正規化してから比較する。濁点が結合文字に分解された文字列（NFD）でも一致する。
- **和暦**：システムの暦法が和暦だと `Calendar.current` が `.japanese` になり、`dueDateComponents` に入れると EventKit が例外を投げる。日付の組み立ては常に `Calendar(identifier: .gregorian)` を使う。
- **4年制限**：`predicateForEvents` は4年を超える期間を黙って先頭4年に切り詰める。3年ずつのウィンドウに分割して全件取得している。
- **終日判定**：EventKit は `DateComponents` に hour/minute が無いと自動的に終日扱いにする。
- **リマインダーは非同期、イベントは同期**：`fetchReminders` はコールバック、`events(matching:)` は同期。前者は `DispatchSemaphore` で待つ（コールバックは任意のキューで呼ばれるのでメインスレッドをブロックしてもデッドロックしない）。
- **stdout を汚さない**：MCP の stdio トランスポートは stdout を占有する。子プロセスは `stdio: ["ignore", "pipe", "pipe"]` で起動し、ログは stderr に出す。`"inherit"` にするとプロトコルが壊れて無言でハングする。

## 開発

MCP サーバーを生の JSON-RPC で叩く検証用クライアントを同梱している。

```bash
cd ts
node test-mcp.mjs '[["reminder_lists",{}],["reminders",{"list":"買い物リスト"}]]'
```

## ライセンス

MIT
