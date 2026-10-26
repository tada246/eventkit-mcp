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
| Swift | 6.0 以上（Xcode のツールチェーン）|
| Node.js | 22 以上 |

macOS 27.0 / Xcode 27.1（Swift 6.4）/ Node 24.14.1 で動作確認。

## ビルド

```bash
./build.sh                      # Swift CLI をビルドして bin/EventKitCLI.app を作る
cd ts && npm install && npm run build
```

`build.sh` は `bin/EventKitCLI.app` を生成する。**素の実行ファイルではなく .app バンドルなのは TCC の都合**（後述）。

`build.sh` は `xcrun swift build` を使う。swiftly などで別に入れた `swift` が PATH の先にあると、Xcode の SDK と版がずれて `unknown argument: '-target-arch-variant'` で失敗することがあるため。

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

他のカレンダー系 MCP と区別しやすいよう、全ツールに `apple_` を付けている。

| ツール | 必須引数 | 説明 |
|---|---|---|
| `apple_reminder_lists` | — | リマインダーのリスト一覧 |
| `apple_reminders` | — | リマインダー取得。`list` 省略で全リスト、既定は未完了のみ |
| `apple_search_reminders` | — | 名前とメモを対象に検索。`query` 省略で全件 |
| `apple_create_reminder` | `title` | 作成。`list` `due` `notes` `priority` `alarms` |
| `apple_update_reminder` | `id` か `ids` | 更新。`title` `list`（移動）`due` `notes` `priority` `alarms` `completed` |
| `apple_complete_reminder` | `id` | 完了にする |
| `apple_delete_reminder` | `id` か `ids` | 削除。削除前の内容を返す |
| `apple_calendars` | — | カレンダー一覧 |
| `apple_events` | `from` `to` | 期間内のイベント |
| `apple_search_events` | — | タイトル・場所・メモを対象に検索。`query` 省略で期間内全件 |
| `apple_create_event` | `title` `start` | 作成。`end` `calendar` `location` `notes` `allDay` `alarms` `recurrence` `exclude` |
| `apple_update_event` | `id` か `ids` | 更新。`occurrence` `span` で繰り返しの対象を選ぶ。`calendar` で移動 |
| `apple_delete_event` | `id` か `ids` | 削除。`occurrence` `span` で繰り返しの対象を選ぶ。削除前の内容を返す |

読み取り系には `readOnlyHint`、削除系には `destructiveHint` の annotation を付けている。削除は取り消せないので、結果に削除前の内容をそのまま返す（必要なら手で作り直せる）。

### 日時

- `2026-08-10` … 終日
- `2026-08-10T15:30:00` … 時刻付き（ローカルタイムゾーン）。`+09:00` などのオフセット付きも可

**終日イベントの `end` は最終日（その日を含む）。** 8/22〜8/23 の2日間なら `start: "2026-08-22", end: "2026-08-23"`。1日だけなら `end` は省略できる。`start` が日付だけなら `allDay` を省略しても終日になる。

優先度は EventKit の仕様に従い 0〜9（`0`=なし、`1-4`=高、`5`=中、`6-9`=低）。範囲外は保存前に弾く。

### 値を消す

更新系では、省略した項目は変更せず、`null` を渡した項目は消す。

```json
{ "id": "…", "due": null, "notes": null }
```

`ids` を渡すと同じ変更を全件に当てる。1件でも見つからなければ何も変更しない。

### アラーム

```json
"alarms": [{ "minutesBefore": 30 }, { "at": "2026-11-01T08:00:00" }]
```

- `minutesBefore` はイベントなら開始、リマインダーなら期限の何分前か。リマインダーは期限から計算した絶対時刻で保存する
- 時刻付きの期限でリマインダーを作ると、`alarms` を省略しても期限ちょうどのアラームが1つ付く（リマインダーApp と同じ挙動）。`alarms: []` で付けない
- 更新時の `alarms` は全置換。`[]` か `null` で全部消す

### 繰り返し

```json
"recurrence": { "frequency": "weekly", "interval": 2, "daysOfWeek": ["mon", "thu"], "until": "2027-01-20" },
"exclude": ["2026-11-03"]
```

- `frequency` は `daily` `weekly` `monthly` `yearly`。`until`（その日を含む）と `count` はどちらか一方
- **`start` は最初の回にする。** `daysOfWeek` が `start` の曜日を含まないとエラー
- `exclude` は作成後にその日の回を消す（EventKit に除外日を直接書く API が無いため）。該当する回が無い日付は `excludeNotFound` で返す

### 繰り返しイベントの更新・削除

繰り返しは全回が同じ `id` を持つので、`occurrence`（取得結果の `occurrence` をそのまま）と `span`（`"this"` この回だけ / `"future"` この回以降）で対象を選ぶ。

- `occurrence` を省略するとシリーズの最初の回が対象になる。このときは `span` を明示しないとエラー（影響範囲が大きく違うので暗黙に決めない）。`span: "future"` でシリーズ全体になる
- 1回だけ変更した回は `id` の末尾に `/RID=…` が付く。シリーズの `id` と `occurrence` でも引ける
- カレンダー移動はシリーズ全体にしか効かないので、`span: "future"` で最初の回を対象にしたときだけ受け付ける

### タイムアウト

CLI が 45 秒（`EVENTKIT_MCP_TIMEOUT_MS` で変更可）以内に返らなければ kill して `isError` を返す。権限待ちは CLI 側で 30 秒まで。作成系がタイムアウトしたときはタイトルで検索し直し、見つかったものを `possiblyCreated` に入れて返す（作り直す前に確認できるように）。

### 1.x からの移行

2.0.0 でツール名がすべて `apple_` 付きに変わった。旧名のエイリアスは無い。MCP クライアントを再起動すれば新しい名前が見える。

## CLI サブコマンド

```bash
eventkit-cli lists
eventkit-cli reminders --list <名前> [--include-completed]
eventkit-cli reminders --all [--include-completed]
eventkit-cli search [<文字列>] [--list <名前>] [--include-completed]
eventkit-cli create-reminder --title <名前> [--list <名前>] [--due <日時>] [--notes <メモ>] [--priority 0-9] [--alarms '<JSON>']
eventkit-cli update-reminder --id <ID>|--ids '<JSON>' [--title …] [--list …] [--due …] [--notes …] [--priority …] [--alarms '<JSON>'] [--completed true|false] [--clear due,notes,alarms]
eventkit-cli complete-reminder <ID>
eventkit-cli delete-reminder --id <ID>|--ids '<JSON>'

eventkit-cli calendars
eventkit-cli events --from <日付> --to <日付> [--calendar <名前>]
eventkit-cli search-events [<文字列>] [--from <日付>] [--to <日付>]
eventkit-cli create-event --title <名前> --start <日時> [--end <日時>] [--calendar <名前>] [--location <場所>] [--notes <メモ>] [--all-day] [--alarms '<JSON>'] [--recurrence '<JSON>'] [--exclude '<JSON>']
eventkit-cli update-event --id <ID>|--ids '<JSON>' [--occurrence <日時>] [--span this|future] [--title …] [--start …] [--end …] [--all-day true|false] [--calendar …] [--location …] [--notes …] [--alarms '<JSON>'] [--recurrence '<JSON>'] [--clear location,notes,alarms,recurrence]
eventkit-cli delete-event --id <ID>|--ids '<JSON>' [--occurrence <日時>] [--span this|future]

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

Info.plist の中身を変えた場合も再許可を求められることがある（2.0.0 で usage description の文言を変えたときに実測）。なお `diag` は自分では権限を要求しないので、再ビルド直後は `notDetermined` と表示されることがあるが、実際のコマンドを1回走らせれば許可済みとして通る。

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

### テスト

```bash
xcrun swift test --package-path swift   # Swift の単体テスト（EventKit のストアには触らない）
cd ts && npm test                       # TS の単体・MCP 結合テスト（偽の CLI を使う）
cd ts && npm run test:e2e               # 本物の EventKit を使う E2E
```

**`test:e2e` は実データに触る。** iCloud の「リマインダー」「買い物リスト」と「自宅」「職場」カレンダーに、タイトルが `[eventkit-mcp-e2e <ランダムID>]` で始まる 2027 年の項目を作り、最後に全部消して0件であることを確かめる。iCloud 経由で他の端末にも一瞬表示される。

### 検証用クライアント

MCP サーバーを生の JSON-RPC で叩く検証用クライアントを同梱している。

```bash
cd ts
node test-mcp.mjs '[["apple_reminder_lists",{}],["apple_reminders",{"list":"買い物リスト"}]]'
```

`EVENTKIT_CLI_BIN` を指定すると、本物の代わりに別の CLI を起動する（テスト用）。

## ライセンス

MIT
