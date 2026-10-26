# 設計書：Issue #1〜#6 の一括対応

ブランチ：`feature/resolve-issues-1-6`
対象：#1 イベント更新・削除 / #2 リマインダー更新・削除 / #3 繰り返し / #4 アラーム / #5 タイムアウト / #6 ツールの見つけやすさ

## 0. 方針

- 1ブランチ・1PR でまとめて出し、`Closes #1`〜`#6` で閉じる。
- ツール名を変えるので **破壊的変更**。バージョンを `2.0.0` にする。
- **worktree は使わない。** TCC の許可が `bin/EventKitCLI.app` の実パスに紐づいているため、別ディレクトリでビルドすると再許可が必要になる。作業はこのチェックアウトで行う。
- 「削除は意図的に実装しない」という README の方針は撤回する。代わりに、削除系ツールは MCP の `destructiveHint` を付け、削除前の内容を丸ごと返す（手で復元できるように）。

## 1. ツール一覧（変更後）

全ツールに `apple_` を付ける（#6）。旧名のエイリアスは置かない。ツール数が倍になると検索でかえって埋もれるため。

| 新ツール名 | 旧名 | 区分 | Issue |
|---|---|---|---|
| `apple_reminder_lists` | `reminder_lists` | 読み取り | #6 |
| `apple_reminders` | `reminders` | 読み取り | #6 |
| `apple_search_reminders` | `search_reminders` | 読み取り | #6 |
| `apple_create_reminder` | `create_reminder` | 作成 | #4 #5 |
| `apple_update_reminder` | **新規** | 更新 | #2 #4 |
| `apple_complete_reminder` | `complete_reminder` | 更新 | — |
| `apple_delete_reminder` | **新規** | 削除 | #2 |
| `apple_calendars` | `calendars` | 読み取り | #6 |
| `apple_events` | `events` | 読み取り | #6 |
| `apple_search_events` | `search_events` | 読み取り | #6 |
| `apple_create_event` | `create_event` | 作成 | #3 #4 #6 |
| `apple_update_event` | **新規** | 更新 | #1 #3 #4 |
| `apple_delete_event` | **新規** | 削除 | #1 |

各ツールに MCP の `annotations` を付ける：読み取りは `readOnlyHint: true`、削除は `destructiveHint: true`。

## 2. 共通仕様

### 2.1 値を消す操作

更新系では **`null` を渡すとその項目を消す**。省略した項目は変更しない。

```json
{ "id": "…", "due": null, "notes": null }   // 期限とメモを外す
```

CLI には `--clear due,notes` のようにカンマ区切りで渡す。

### 2.2 アラーム（#4）

`alarms` は配列。要素は次のどちらか。

```json
{ "minutesBefore": 30 }               // 相対：イベントは開始、リマインダーは期限の30分前
{ "at": "2026-11-01T08:00:00" }        // 絶対時刻
```

- `minutesBefore` は 0 以上の整数（0 = ちょうど）。
- イベントは `EKAlarm(relativeOffset:)` を使う。リマインダーは相対オフセットの基準が分かりにくいので、**期限から計算した絶対時刻**の `EKAlarm(absoluteDate:)` にする。期限がないリマインダーに相対指定したらエラー。
- 更新系の `alarms` は**全置換**。`alarms: []` または `null` で全削除。
- 取得結果（`ReminderOut` / `EventOut`）に `alarms` を出す。相対は `{minutesBefore}`、絶対は `{at}`。

**リマインダーの既定アラーム**：`apple_create_reminder` で `due` に時刻があり、`alarms` を省略したときは、期限ちょうどのアラームを1つ自動で付ける。リマインダーApp で日時を入れたときの挙動（その時刻に通知）に合わせるため。付けたくなければ `alarms: []` を渡す。終日の期限には付けない。

### 2.3 繰り返し（#3）

```json
"recurrence": {
  "frequency": "weekly",            // daily | weekly | monthly | yearly
  "interval": 2,                    // 省略時 1。隔週なら 2
  "daysOfWeek": ["mon", "thu"],     // weekly のときだけ。省略で start の曜日
  "until": "2027-01-20",            // until と count はどちらか一方。両方省略で無期限
  "count": 14
},
"exclude": ["2026-11-03", "2026-11-23"]   // 祝日などで休みの回
```

- `EKRecurrenceRule` を組み立てて `event.recurrenceRules = [rule]` で保存する。
- `until` は終日の日付として扱い、その日の 23:59:59 までの回を含む。
- **`start` は最初の回にする**ことを説明に書く。EventKit は `start` が `daysOfWeek` に合わない曜日でも、その日を1回目として作ってしまうため。合わない場合はエラーにする。
- `exclude`：EventKit には除外日（EXDATE）を直接書く API がない。保存後に該当日の回を取得して `span: .thisEvent` で削除する。該当する回がない日付はエラーにせず、結果の `excludeNotFound` に入れて返す。
- 結果の `EventOut` に `recurrence`（上と同じ形）と `occurrence`（その回の開始日時）を出す。

### 2.4 繰り返しイベントの更新・削除の対象指定（#1）

繰り返しイベントは全回が同じ `eventIdentifier` を共有するので、ID だけでは回を特定できない。

| 引数 | 意味 |
|---|---|
| `id` | `apple_events` / `apple_search_events` の `id` |
| `occurrence` | どの回か。結果の `occurrence` をそのまま渡す。繰り返しでなければ不要 |
| `span` | `"this"`（この回だけ、既定）/ `"future"`（この回以降すべて） |

- 繰り返しイベントで `occurrence` を省略したら、**シリーズの最初の回**が対象になる。このとき `span` を明示しないとエラー（`this` か `future` かで影響範囲が大きく違うので、暗黙に決めない）。
- カレンダー移動は EventKit の制約でシリーズ全体にしか効かない。繰り返しイベントで `calendar` を変えるときは `span: "future"` かつ最初の回を対象にする必要がある。それ以外はエラーにする。（実装時に実機で挙動を確認し、違えば合わせる）

### 2.5 一括処理（#1 #2）

`apple_delete_event` / `apple_delete_reminder` は `ids` 配列も受ける。`apple_update_event` / `apple_update_reminder` も `ids` を受け、**同じ変更を全件に適用**する（例：14件まとめてカレンダー移動、7件まとめてリスト移動）。

- 全件を先に解決し、1件でも見つからなければ**何も変更せずにエラー**。
- 保存は `commit: false` で積んでから最後に `store.commit()`。途中で失敗したら `store.reset()` で捨てる。
- 個別に違う変更をしたいときは1件ずつ呼ぶ。

## 3. ツール別の仕様

### 3.1 `apple_update_reminder`（#2）

| 引数 | 型 | 備考 |
|---|---|---|
| `id` / `ids` | string / string[] | どちらか必須 |
| `title` | string | |
| `list` | string | リスト移動 |
| `due` | string \| null | null で期限を外す |
| `notes` | string \| null | |
| `priority` | 0〜9 | |
| `alarms` | Alarm[] \| null | 全置換 |
| `completed` | boolean | `false` で未完了に戻す |

`due` を変えて `alarms` を省略したとき、既存のアラームはそのまま残す（勝手に動かさない）。

### 3.2 `apple_delete_reminder`（#2）

`id` か `ids`。結果は `{"deleted": [ReminderOut…]}`。

### 3.3 `apple_create_event` の追加分（#3 #4 #6）

- `alarms`、`recurrence`、`exclude` を追加。
- **終日イベントの書き方を明確にする**（#6 の「複数日の終日イベントを1日ずつ作られた」対策）。
  - `allDay: true` のとき `start` / `end` は `yyyy-MM-dd`。**`end` は最終日（その日を含む）**。8/22〜8/23 の2日間なら `start: "2026-08-22", end: "2026-08-23"`。
  - 1日だけなら `end` は省略可。
  - `start` が日付だけで `allDay` を省略した場合も終日として扱う。
  - 実装時に実機で `end` の保存結果を確かめ、読み戻した `end` が指定どおりになることをテストで固定する。
- `end` は `allDay` 以外では必須のまま。

### 3.4 `apple_update_event`（#1）

| 引数 | 型 | 備考 |
|---|---|---|
| `id` / `ids` | string / string[] | |
| `occurrence` | string | 2.4 参照。`ids` とは併用不可 |
| `span` | `"this"` \| `"future"` | |
| `title` `start` `end` `allDay` | | `start` だけ変えたら長さを保って `end` もずらす |
| `calendar` | string | 2.4 の制約あり |
| `location` `notes` | string \| null | |
| `alarms` | Alarm[] \| null | 全置換 |
| `recurrence` | Recurrence \| null | null で繰り返しをやめる |

### 3.5 `apple_delete_event`（#1）

`id`（＋`occurrence` `span`）か `ids`。結果は `{"deleted": [EventOut…]}`。

### 3.6 `apple_search_reminders` / `apple_search_events`（#6）

`query` を省略可・空文字可にする。空なら全件（`apple_reminders` と同じ）。説明文でも「全件なら `apple_reminders`」と誘導する。

## 4. タイムアウト（#5）

### 4.1 原因の見立て

- TS の `run()` にタイムアウトがない。子プロセスが詰まると MCP クライアント側のタイムアウトまで待ち、何も返らない。
- TS が `EVENTKIT_CLI_ACCESS_TIMEOUT=120` を渡しており、権限待ちが最大120秒になる。クライアントのタイムアウトより長い。
- 権限ダイアログが他のウィンドウの裏に出ていると、ユーザーは気づかない。

### 4.2 対策

1. **TS 側に子プロセスのタイムアウト**を付ける。既定 45 秒、`EVENTKIT_MCP_TIMEOUT_MS` で変更可。超えたら SIGTERM → 2秒後に SIGKILL し、`isError: true` で理由を返す。
2. 権限待ちは CLI 側で 30 秒（TS のタイムアウトより短く）。権限待ちで止まったことが分かるメッセージにする（現状のメッセージを、どの権限か・何をすればいいかが分かる文言に）。
3. **権限ステータスの事前チェック**：`notDetermined` のときは「ダイアログが出ているはず。Mac の画面を確認」と stderr に出してから待つ。`denied` なら待たずに即エラー（システム設定 > プライバシー の場所を案内）。
4. **作成系がタイムアウトしたとき、作成されたかを確認**して返す。TS が続けて検索を1回走らせ（リマインダーはタイトルで、イベントはタイトル＋開始日の範囲で）、見つかれば `possiblyCreated` としてエラー結果に含める。ツール説明にも「タイムアウトしたら再作成せず、まず検索で確認」と書く。冪等キーは EventKit に保存場所がない（メモ欄を汚す）ので採らない。

## 5. ツール説明の改善（#6）

- 全説明に「Apple」「Mac」「macOS」「iCloud」と、日英の同義語（予定/schedule/appointment、todo/task、一覧/list）を入れる。
- 先頭に「何をするツールか」を英語で1文、続けて日本語。検索は英語クエリが多いので英語を先に。
- `apple_calendars` などは「NOT Google Calendar」を残す。
- 終日イベント、繰り返し、`occurrence`、`null` で消す、をそれぞれのツール説明と引数説明に書く。

## 6. コード構成の変更

テストを書けるようにするため、副作用のない部分をライブラリに分ける。

```
swift/
  Sources/
    EventKitCore/          ← 新規ライブラリ。EventKit のストアに触らない純粋な処理
      Args.swift           （移動）
      Dates.swift          日付パース・フォーマット（throws に変更）
      Recurrence.swift     JSON 仕様 ⇔ EKRecurrenceRule
      Alarms.swift         JSON 仕様 ⇔ EKAlarm
    eventkit-cli/          ← 実行ファイル。ストアを触る処理と main
      main.swift Store.swift Reminders.swift Calendars.swift Diag.swift Disclaim.swift
  Tests/
    EventKitCoreTests/     swift-testing
ts/
  src/
    index.ts               MCP サーバーの組み立て
    cli.ts                 子プロセス実行（タイムアウト、バイナリパスは EVENTKIT_CLI_BIN で差し替え可）
    tools.ts               ツール定義と引数→CLI フラグの変換
  test/
    unit.test.ts           フラグ変換・タイムアウト（偽の CLI を使う）
    mcp.test.ts            dist/index.js を起動して tools/list・tools/call を検査（偽の CLI）
    e2e.test.ts            本物の EventKit を使う（opt-in）
```

- 繰り返しやアラームのような構造化引数は、CLI に `--recurrence '<JSON>'` `--alarms '<JSON>'` として JSON 文字列で渡す。フラグを細かく分けるより TS と Swift で仕様を1つにできる。
- EventKit 由来の型（`EKRecurrenceRule` など）はテストプロセスでも権限なしで生成できるので、変換ロジックはライブラリ側で単体テストする。

## 6.1 CLI の入出力仕様（Swift と TS の契約）

出力は常に stdout に JSON 1つ。エラーは `{"error": "…"}` で exit 1。構造化値は JSON 文字列で渡す。`--clear` はカンマ区切りのフィールド名。

| サブコマンド | フラグ | 出力 |
|---|---|---|
| `search [<query>]` | 既存どおり。query 省略・空文字で全件 | 既存どおり |
| `create-reminder` | 既存 + `--alarms '<Alarm[]>'`（省略で 2.2 の既定、`[]` でなし） | `{"created": Reminder}` |
| `update-reminder` | `--id <ID>` か `--ids '<string[]>'`、`--title` `--list` `--due` `--notes` `--priority` `--alarms` `--completed true\|false` `--clear due,notes,alarms` | `{"updated": [Reminder]}` |
| `delete-reminder` | `--id` か `--ids` | `{"deleted": [Reminder]}` |
| `search-events [<query>]` | 既存どおり。query 省略・空文字で期間内全件 | 既存どおり |
| `create-event` | 既存 + `--alarms` `--recurrence '<Recurrence>'` `--exclude '<string[]>'`。`--end` は終日なら省略可。`--start` が日付だけなら終日 | `{"created": Event, "excludeNotFound": [string]}`（後者は該当なしの日付があるときだけ。エラーにはしない） |
| `update-event` | `--id` か `--ids`、`--occurrence <日時>` `--span this\|future`、`--title` `--start` `--end` `--all-day true\|false` `--calendar` `--location` `--notes` `--alarms` `--recurrence` `--clear location,notes,alarms,recurrence` | `{"updated": [Event]}` |
| `delete-event` | `--id` か `--ids`、`--occurrence` `--span` | `{"deleted": [Event]}` |

出力オブジェクトへの追加：

- Reminder：`alarms: Alarm[]`（リマインダーは常に `{at}` 形式）
- Event：`occurrence: string`（その回の開始。終日なら `yyyy-MM-dd`、それ以外は ISO8601）、`recurrence: Recurrence | null`、`alarms: Alarm[]`

`--occurrence` は `occurrence` の値をそのまま受け、同じ `eventIdentifier` で開始が一致する回を探す（その日の前後1日を取得して比較）。

## 7. テスト計画

| 層 | コマンド | 内容 | 実データに触るか |
|---|---|---|---|
| Swift 単体 | `swift test --package-path swift` | 日付パース、終日の `end`、繰り返しルール（隔週・曜日・until/count・不正値）、アラーム変換、Args | 触らない |
| TS 単体 | `npm test` | 引数→フラグ変換、`null`→`--clear`、タイムアウトで kill して isError、タイムアウト後の作成確認 | 触らない（偽 CLI） |
| MCP 結合 | `npm test` | 全13ツールが `apple_` 付きで出る、annotations、スキーマ | 触らない（偽 CLI） |
| E2E | `npm run test:e2e` | 本物の CLI で作成→取得→更新→削除を一巡 | **触る**（下記） |

**E2E の実データへの影響**：iCloud の既定リスト「リマインダー」と既定カレンダー「自宅」（移動テストは「職場」）に、タイトル先頭が `[eventkit-mcp-e2e <ランダムID>]` のテスト項目を作り、テストの最後に必ず削除する。終了後にその接頭辞で検索して0件であることを確認する。iCloud 経由で他の端末にも一瞬表示される。日付は今日から十分先（来年）の範囲を使う。

E2E で確かめること：
- リマインダー：作成（時刻付き期限→既定アラームが付く）、更新（優先度・リスト移動・期限を外す・未完了に戻す）、削除、一括削除
- イベント：終日2日間の `end` が読み戻しで一致、隔週・曜日指定・`until`・`exclude` で回数が合う、`occurrence`+`span:this` で1回だけ変更、`span:future`、カレンダー移動、相対アラーム、削除、一括削除
- タイムアウト：`EVENTKIT_MCP_TIMEOUT_MS` を極小にして isError が返る

## 8. 進め方（Go 後に自走する範囲）

1. Swift のライブラリ分割と単体テスト
2. Swift の新機能（更新・削除・繰り返し・アラーム・権限チェック）
3. TS の分割、タイムアウト、ツール定義の書き直しと単体・結合テスト
4. `./build.sh` と `npm run build` でビルド（同じパスに再ビルドするので権限は維持される見込み）
5. E2E 実行、後片付けの確認
6. README 更新（ツール表、削除方針、アラーム・繰り返しの書き方、テスト手順、2.0.0 の移行メモ）
7. コミット → push → PR 作成（`Closes #1`〜`#6`）→ main へマージ

マージ後、Claude Desktop / Claude Code の再起動が必要（ツール名が変わるため）。これはこちらではできないのでお願いする。

## 9. やらないこと

- Developer ID 署名・`.app` の固定パス化（TCC のパス依存の解消）
- GitHub Actions での CI（macOS ランナーで TCC 許可を出せないため E2E は回せない。単体テストだけの CI は別途）
- 旧ツール名のエイリアス
- 場所ベースのアラーム、繰り返しの `daysOfMonth` / 「第2火曜」など高度なルール

## 10. 決めてほしいこと（推奨どおりで良ければ Go だけで OK）

| # | 論点 | 推奨 |
|---|---|---|
| A | ツール名に `apple_` を付ける（破壊的変更） | 付ける。旧名エイリアスなし |
| B | 時刻付き期限のリマインダーに既定でアラームを付ける | 付ける（`alarms: []` で無効化） |
| C | 削除ツールを入れる | 入れる。削除前の内容を返す |
| D | E2E で実際の iCloud の「リマインダー」「自宅」「職場」に一時項目を作って消す | 実施する |
| E | 取り込みは PR を作ってそのまま main にマージ | マージまでやる |

## 11. 実装後のメモ（設計からの差分）

- 終日の `end`：`endDate` に「最終日の 0 時」を入れると、その日を含む期間として保存される。E2E で読み戻しを確認済み。
- 1回だけ変更した回は独立した回になり、`eventIdentifier` の末尾に `/RID=…` が付く。シリーズ ID + `occurrence` でも引けるようにした。シリーズを `span: future` で消すと、独立した回も一緒に消える。
- イベントの引き当ては `store.event(withIdentifier:)`。`calendarItem(withIdentifier:)` は `eventIdentifier` では引けない。
- 繰り返しでないイベントに `occurrence` を渡したらエラーにした。
- ツール入力スキーマの最上位に `anyOf` を置かない（Claude の API が受け付けない）。`id` / `ids` のどちらか必須は CLI 側で検査する。
- `build.sh` は `xcrun swift build` に変えた。swiftly の Swift 6.3.1 が Xcode 27.1 の SDK とかみ合わず、ビルドできなかったため。
- 再ビルドで TCC の許可がリセットされ、ダイアログで許可し直した（Info.plist の文言変更が原因とみている）。
