import type { JsonSchemaType } from "@modelcontextprotocol/server";
import { CliTimeoutError, run, type Json } from "./cli.js";

export type ToolArgs = Record<string, unknown>;

export type ToolAnnotations = {
  readOnlyHint?: boolean;
  destructiveHint?: boolean;
};

export type ToolDef = {
  name: string;
  title: string;
  description: string;
  inputSchema: JsonSchemaType;
  annotations?: ToolAnnotations;
  buildArgs: (args: ToolArgs) => string[];
};

export type ToolResult = {
  content: { type: "text"; text: string }[];
  isError?: boolean;
};

// 作成がタイムアウトしたときの確認検索は、ユーザーを待たせないよう短く打ち切る。
const FOLLOW_UP_TIMEOUT_MS = 10_000;

const ALARM_SCHEMA: JsonSchemaType = {
  type: "object",
  properties: {
    minutesBefore: {
      type: "integer",
      minimum: 0,
      description: "相対アラーム。イベントは開始、リマインダーは期限の何分前か（0=ちょうど）",
    },
    at: {
      type: "string",
      description: "絶対アラーム。yyyy-MM-ddTHH:mm:ss（ローカルタイムゾーン）",
    },
  },
  additionalProperties: false,
};

const RECURRENCE_PROPERTIES = {
  frequency: {
    type: "string",
    enum: ["daily", "weekly", "monthly", "yearly"],
    description: "繰り返しの頻度",
  },
  interval: {
    type: "integer",
    minimum: 1,
    description: "間隔。省略時 1、隔週なら 2",
  },
  daysOfWeek: {
    type: "array",
    items: { type: "string", enum: ["sun", "mon", "tue", "wed", "thu", "fri", "sat"] },
    description: "weekly のときだけ。省略時は start の曜日",
  },
  until: {
    type: "string",
    description: "yyyy-MM-dd。その日の 23:59:59 までを含む（count とはどちらか一方）",
  },
  count: {
    type: "integer",
    minimum: 1,
    description: "回数（until とはどちらか一方）",
  },
} satisfies Record<string, JsonSchemaType>;

const RECURRENCE_SCHEMA: JsonSchemaType = {
  type: "object",
  properties: RECURRENCE_PROPERTIES,
  required: ["frequency"],
  additionalProperties: false,
};

const alarms = (description: string): JsonSchemaType => ({
  type: "array",
  items: ALARM_SCHEMA,
  description,
});

const nullableAlarms = (description: string): JsonSchemaType => ({
  type: ["array", "null"],
  items: ALARM_SCHEMA,
  description,
});

const nullableString = (description: string): JsonSchemaType => ({
  type: ["string", "null"],
  description,
});

const idProps = {
  id: { type: "string", description: "対象の ID（apple_reminders / apple_events などで取得）" },
  ids: {
    type: "array",
    items: { type: "string" },
    description: "複数 ID。同じ変更を全件に適用する（id とはどちらか一方）",
  },
} satisfies Record<string, JsonSchemaType>;

const OCCURRENCE_PROPS = {
  occurrence: {
    type: "string",
    description:
      "繰り返しイベントのどの回か。結果の occurrence をそのまま渡す。省略時は最初の回（このとき span 必須）",
  },
  span: {
    type: "string",
    enum: ["this", "future"],
    description: "this=この回だけ（既定）/ future=この回以降すべて",
  },
} satisfies Record<string, JsonSchemaType>;

// ---- 引数 → CLI フラグ ----

function addString(out: string[], args: ToolArgs, key: string, flag: string): void {
  const v = args[key];
  if (v === undefined || v === null || v === "") return;
  out.push(flag, String(v));
}

function addBoolFlag(out: string[], args: ToolArgs, key: string, flag: string): void {
  if (args[key] === true) out.push(flag);
}

// 更新系は false も明示して送る（--completed false / --all-day false）。
function addBoolValue(out: string[], args: ToolArgs, key: string, flag: string): void {
  const v = args[key];
  if (typeof v === "boolean") out.push(flag, String(v));
}

function addJson(out: string[], args: ToolArgs, key: string, flag: string): void {
  const v = args[key];
  if (v !== undefined) out.push(flag, JSON.stringify(v));
}

// null は項目を消す指定なので、後でまとめて --clear a,b にする。
function addNullableString(
  out: string[], clear: string[], args: ToolArgs, key: string, flag: string
): void {
  const v = args[key];
  if (v === undefined) return;
  if (v === null) {
    clear.push(key);
    return;
  }
  if (v === "") return;
  out.push(flag, String(v));
}

function addNullableJson(
  out: string[], clear: string[], args: ToolArgs, key: string, flag: string
): void {
  const v = args[key];
  if (v === undefined) return;
  if (v === null) {
    clear.push(key);
    return;
  }
  out.push(flag, JSON.stringify(v));
}

function addIds(out: string[], args: ToolArgs): void {
  if (Array.isArray(args.ids)) {
    out.push("--ids", JSON.stringify(args.ids));
    return;
  }
  addString(out, args, "id", "--id");
}

function addOccurrence(out: string[], args: ToolArgs): void {
  addString(out, args, "occurrence", "--occurrence");
  addString(out, args, "span", "--span");
}

function addQuery(out: string[], args: ToolArgs): void {
  const q = args.query;
  if (typeof q === "string" && q !== "") out.push(q);
}

function addClear(out: string[], clear: string[]): void {
  if (clear.length > 0) out.push("--clear", clear.join(","));
}

// ---- ツール定義 ----

export const TOOLS: ToolDef[] = [
  {
    name: "apple_reminder_lists",
    title: "Apple リマインダーのリスト一覧",
    description:
      "List all reminder lists in Apple Reminders on this Mac (macOS, iCloud, local). " +
      "Use this first to discover list names for reminders, todos, and tasks. " +
      "Returns each list's name, id, source, and whether it is the default. NOT Google Tasks. " +
      "Apple リマインダーApp（macOS / iCloud）のリスト一覧（名前とID）を全部返す。" +
      "todo・task・一覧のリスト名を確認したいときに使う。Google Tasks ではない。",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: { readOnlyHint: true },
    buildArgs: () => ["lists"],
  },
  {
    name: "apple_reminders",
    title: "Apple リマインダーの取得",
    description:
      "Get reminders (todos / tasks) from Apple Reminders on this Mac (macOS, iCloud, local). " +
      "Omit list to fetch every list; by default only incomplete items are returned. " +
      "Use apple_search_reminders to filter by text, or apple_reminder_lists to see list names. NOT Google Tasks. " +
      "Apple リマインダーApp（macOS / iCloud）のリマインダー（todo / task）を取得する。" +
      "list を省略すると全リスト、includeCompleted を true にすると完了済みも含む。" +
      "一覧を絞るなら apple_search_reminders を使う。Google Tasks ではない。",
    inputSchema: {
      type: "object",
      properties: {
        list: { type: "string", description: "リスト名。省略すると全リスト" },
        includeCompleted: { type: "boolean", description: "完了済みも含める（既定 false）" },
      },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true },
    buildArgs: (a) => [
      "reminders",
      ...(typeof a.list === "string" && a.list !== "" ? ["--list", a.list] : ["--all"]),
      ...(a.includeCompleted === true ? ["--include-completed"] : []),
    ],
  },
  {
    name: "apple_search_reminders",
    title: "Apple リマインダーの検索",
    description:
      "Search Apple Reminders (todos / tasks) by title and notes on this Mac (macOS, iCloud, local). " +
      "The query is optional: omit it or pass an empty string to return all reminders (same as apple_reminders). " +
      "Case and Japanese NFC/NFD normalization are ignored. NOT Google Tasks. " +
      "Apple リマインダーApp（macOS / iCloud）を名前とメモで検索する。" +
      "query は省略可・空文字可で、その場合は apple_reminders と同じく全件を返す。" +
      "大文字小文字と日本語の正規化揺れは無視する。Google Tasks ではない。",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "検索文字列。省略・空文字なら全件" },
        list: { type: "string", description: "検索対象のリスト名（省略で全リスト）" },
        includeCompleted: { type: "boolean", description: "完了済みも含める（既定 false）" },
      },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true },
    buildArgs: (a) => {
      const out = ["search"];
      addQuery(out, a);
      addString(out, a, "list", "--list");
      addBoolFlag(out, a, "includeCompleted", "--include-completed");
      return out;
    },
  },
  {
    name: "apple_create_reminder",
    title: "Apple リマインダーの作成",
    description:
      "Create a reminder (todo / task) in Apple Reminders on this Mac (macOS, iCloud, local). " +
      "due accepts yyyy-MM-dd (all-day) or yyyy-MM-ddTHH:mm:ss (with time). " +
      "A timed due gets one alarm at the due time by default, even when alarms is omitted; pass alarms: [] to suppress it. " +
      "alarms items are {minutesBefore: 30} or {at: \"2026-11-01T08:00:00\"}. " +
      "On timeout do not recreate blindly: search by title first. NOT Google Tasks. " +
      "Apple リマインダーApp（macOS / iCloud）にリマインダーを作成する。" +
      "due は 2026-08-10 なら終日、2026-08-10T15:30:00 なら時刻付き。" +
      "時刻付きの期限で alarms を省略すると期限ちょうどのアラームが1つ付く（alarms: [] で無効）。" +
      "タイムアウトしたら再作成せず、まず apple_search_reminders で確認する。Google Tasks ではない。",
    inputSchema: {
      type: "object",
      properties: {
        title: { type: "string", description: "リマインダーの名前" },
        list: { type: "string", description: "省略すると既定のリスト" },
        due: { type: "string", description: "yyyy-MM-dd（終日）または yyyy-MM-ddTHH:mm:ss" },
        notes: { type: "string" },
        priority: {
          type: "integer",
          minimum: 0,
          maximum: 9,
          description: "0=なし, 1-4=高, 5=中, 6-9=低",
        },
        alarms: alarms("省略時は時刻付き due に期限ちょうどのアラームを1つ自動付与。[] でなし"),
      },
      required: ["title"],
      additionalProperties: false,
    },
    buildArgs: (a) => {
      const out = ["create-reminder"];
      addString(out, a, "title", "--title");
      addString(out, a, "list", "--list");
      addString(out, a, "due", "--due");
      addString(out, a, "notes", "--notes");
      addString(out, a, "priority", "--priority");
      addJson(out, a, "alarms", "--alarms");
      return out;
    },
  },
  {
    name: "apple_update_reminder",
    title: "Apple リマインダーの更新",
    description:
      "Update one or more existing reminders (todos / tasks) in Apple Reminders on this Mac (macOS, iCloud, local). " +
      "Pass id or ids; with ids the same change is applied to every reminder. " +
      "Omit a field to leave it unchanged; pass null to clear it (due: null, notes: null, alarms: null). " +
      "alarms replaces all alarms: [] or null removes them. completed: false reopens a completed reminder. " +
      "On timeout do not recreate: search first. NOT Google Tasks. " +
      "Apple リマインダーApp（macOS / iCloud）のリマインダーを更新する。" +
      "id か ids を指定（ids は同じ変更を全件に適用）。省略した項目は変更せず、null はその項目を消す。" +
      "alarms は全置換で、[] / null で全削除。completed: false で未完了に戻す。Google Tasks ではない。",
    inputSchema: {
      type: "object",
      properties: {
        ...idProps,
        title: { type: "string" },
        list: { type: "string", description: "移動先のリスト名" },
        due: nullableString("yyyy-MM-dd / yyyy-MM-ddTHH:mm:ss。null で期限を外す"),
        notes: nullableString("null でメモを消す"),
        priority: {
          type: "integer",
          minimum: 0,
          maximum: 9,
          description: "0=なし, 1-4=高, 5=中, 6-9=低",
        },
        alarms: nullableAlarms("全置換。null または [] で全削除"),
        completed: { type: "boolean", description: "true=完了, false=未完了に戻す" },
      },
      additionalProperties: false,
    },
    buildArgs: (a) => {
      const out = ["update-reminder"];
      const clear: string[] = [];
      addIds(out, a);
      addString(out, a, "title", "--title");
      addString(out, a, "list", "--list");
      addNullableString(out, clear, a, "due", "--due");
      addNullableString(out, clear, a, "notes", "--notes");
      addString(out, a, "priority", "--priority");
      addNullableJson(out, clear, a, "alarms", "--alarms");
      addBoolValue(out, a, "completed", "--completed");
      addClear(out, clear);
      return out;
    },
  },
  {
    name: "apple_complete_reminder",
    title: "Apple リマインダーを完了にする",
    description:
      "Mark a reminder (todo / task) as completed (done) in Apple Reminders on this Mac (macOS, iCloud, local). " +
      "Get the id from apple_reminders or apple_search_reminders. " +
      "Use apple_update_reminder with completed: false to reopen it. NOT Google Tasks. " +
      "Apple リマインダーApp（macOS / iCloud）のリマインダーを ID 指定で完了にする。" +
      "ID は apple_reminders / apple_search_reminders で取れる。" +
      "未完了に戻すときは apple_update_reminder の completed: false を使う。Google Tasks ではない。",
    inputSchema: {
      type: "object",
      properties: { id: { type: "string", description: "完了にするリマインダーの ID" } },
      required: ["id"],
      additionalProperties: false,
    },
    buildArgs: (a) => {
      const out = ["complete-reminder"];
      if (a.id !== undefined && a.id !== null && a.id !== "") out.push(String(a.id));
      return out;
    },
  },
  {
    name: "apple_delete_reminder",
    title: "Apple リマインダーの削除",
    description:
      "Delete one or more reminders (todos / tasks) from Apple Reminders on this Mac (macOS, iCloud, local). " +
      "Pass id or ids. This is destructive: the deleted reminders are returned in full so you can recreate them manually if needed. " +
      "On timeout do not assume failure; search before retrying. NOT Google Tasks. " +
      "Apple リマインダーApp（macOS / iCloud）のリマインダーを削除する。id か ids を指定。" +
      "破壊的な操作だが、削除した内容をそのまま返すので手で復元できる。" +
      "タイムアウト時は失敗と決めつけず検索で確認する。Google Tasks ではない。",
    inputSchema: {
      type: "object",
      properties: { ...idProps },
      additionalProperties: false,
    },
    annotations: { destructiveHint: true },
    buildArgs: (a) => {
      const out = ["delete-reminder"];
      addIds(out, a);
      return out;
    },
  },
  {
    name: "apple_calendars",
    title: "Apple カレンダー一覧",
    description:
      "List calendars in Apple Calendar on this Mac (macOS, iCloud, local, NOT Google Calendar). " +
      "Use this first to discover calendar names for events, schedules, and appointments. " +
      "Calendars with allowsModify: false are read-only. " +
      "Apple カレンダーApp（macOS / iCloud）のカレンダー一覧を返す。" +
      "予定・スケジュール・appointment を入れるカレンダー名を確認するときに使う。" +
      "allowsModify が false のものは書き込み不可。Google Calendar ではない。",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: { readOnlyHint: true },
    buildArgs: () => ["calendars"],
  },
  {
    name: "apple_events",
    title: "Apple イベントの取得",
    description:
      "Get events (appointments / schedule) from Apple Calendar on this Mac (macOS, iCloud, local, NOT Google Calendar) for a date range. " +
      "from / to accept yyyy-MM-dd or ISO 8601; a date-only to includes the end of that day. Ranges over 4 years are split internally. " +
      "For text filtering use apple_search_events. " +
      "Apple カレンダーApp（macOS / iCloud）の期間内イベント（予定 / スケジュール / appointment）を取得する。" +
      "from / to は yyyy-MM-dd または ISO8601。日付だけの to はその日の終わりまで含む。" +
      "4年を超える期間も内部で分割して全件返す。Google Calendar ではない。",
    inputSchema: {
      type: "object",
      properties: {
        from: { type: "string", description: "yyyy-MM-dd または ISO8601" },
        to: { type: "string", description: "yyyy-MM-dd または ISO8601（日付ならその日を含む）" },
        calendar: { type: "string", description: "カレンダー名（省略で全部）" },
      },
      required: ["from", "to"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true },
    buildArgs: (a) => {
      const out = ["events"];
      addString(out, a, "from", "--from");
      addString(out, a, "to", "--to");
      addString(out, a, "calendar", "--calendar");
      return out;
    },
  },
  {
    name: "apple_search_events",
    title: "Apple イベントの検索",
    description:
      "Search events (appointments / schedule) in Apple Calendar on this Mac (macOS, iCloud, local, NOT Google Calendar) by title, location, and notes. " +
      "query is optional: omit it or pass an empty string to return all events in the from/to range (same as apple_events). " +
      "If from/to are omitted the default range is 1 year back to 2 years ahead. " +
      "Recurring results include occurrence (the start of that occurrence); pass it to update/delete. " +
      "Apple カレンダーApp（macOS / iCloud）のイベントをタイトル・場所・メモで検索する。" +
      "query は省略可・空文字可で、その場合は期間内の全件を返す（apple_events と同じ）。" +
      "from / to を省略すると前1年〜後2年。繰り返しの結果は occurrence（その回の開始日時）を含む。" +
      "Google Calendar ではない。",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "検索文字列。省略・空文字なら期間内全件" },
        from: { type: "string", description: "yyyy-MM-dd または ISO8601" },
        to: { type: "string", description: "yyyy-MM-dd または ISO8601" },
      },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true },
    buildArgs: (a) => {
      const out = ["search-events"];
      addQuery(out, a);
      addString(out, a, "from", "--from");
      addString(out, a, "to", "--to");
      return out;
    },
  },
  {
    name: "apple_create_event",
    title: "Apple イベントの作成",
    description:
      "Create an event (appointment / schedule) in Apple Calendar on this Mac (macOS, iCloud, local, NOT Google Calendar). " +
      "All-day: set allDay: true and use yyyy-MM-dd for start/end; end is the last day and is inclusive, so start 2026-08-22 with end 2026-08-23 is a 2-day event (omit end for one day). A date-only start is treated as all-day even without allDay. " +
      "For recurrence, start must be the first occurrence and daysOfWeek must include that weekday (weekly mon,thu needs a Monday or Thursday start). exclude lists dates to remove after creation; excludeNotFound reports dates with no occurrence. " +
      "alarms items are {minutesBefore: 30} (relative to start) or {at: \"2026-11-01T08:00:00\"}. " +
      "On timeout do not recreate blindly: search by title first. " +
      "Apple カレンダーApp（macOS / iCloud）にイベント（予定 / スケジュール）を作成する。" +
      "終日は allDay: true と yyyy-MM-dd を使い、end は最終日（その日を含む）。8/22〜8/23 の2日間なら start: \"2026-08-22\", end: \"2026-08-23\"（1日なら end 省略可）。start が日付だけなら allDay 省略でも終日。" +
      "繰り返しは start を最初の回にし、weekly の daysOfWeek は start の曜日を含めること。exclude は作成後に消す日付。" +
      "タイムアウトしたら再作成せず、まず apple_search_events で確認する。Google Calendar ではない。",
    inputSchema: {
      type: "object",
      properties: {
        title: { type: "string" },
        start: { type: "string", description: "yyyy-MM-dd（終日）または yyyy-MM-ddTHH:mm:ss" },
        end: {
          type: "string",
          description: "終日なら最終日（その日を含む）。1日だけなら省略可。時刻付きなら必須",
        },
        calendar: { type: "string", description: "省略すると既定のカレンダー" },
        location: { type: "string" },
        notes: { type: "string" },
        allDay: { type: "boolean", description: "true で終日。true のとき end は最終日を含む" },
        alarms: alarms("省略でアラームなし。相対は開始基準、絶対は {at}"),
        recurrence: RECURRENCE_SCHEMA,
        exclude: {
          type: "array",
          items: { type: "string" },
          description: "祝日などで休みにする日付（yyyy-MM-dd）。該当なしは excludeNotFound に入る",
        },
      },
      required: ["title", "start"],
      additionalProperties: false,
    },
    buildArgs: (a) => {
      const out = ["create-event"];
      addString(out, a, "title", "--title");
      addString(out, a, "start", "--start");
      addString(out, a, "end", "--end");
      addString(out, a, "calendar", "--calendar");
      addString(out, a, "location", "--location");
      addString(out, a, "notes", "--notes");
      addBoolFlag(out, a, "allDay", "--all-day");
      addJson(out, a, "alarms", "--alarms");
      addJson(out, a, "recurrence", "--recurrence");
      addJson(out, a, "exclude", "--exclude");
      return out;
    },
  },
  {
    name: "apple_update_event",
    title: "Apple イベントの更新",
    description:
      "Update one or more existing events (appointments / schedule) in Apple Calendar on this Mac (macOS, iCloud, local, NOT Google Calendar). " +
      "Pass id or ids; with ids the same change is applied to every event. " +
      "For a recurring event pass occurrence (from apple_events / apple_search_events) and span: \"this\" for one occurrence or \"future\" for this and all later occurrences. " +
      "occurrence cannot be combined with ids. A single occurrence that was changed gets its own id ending in /RID=…; the series id plus occurrence still finds it. " +
      "If occurrence is omitted on a recurring event, the first occurrence is targeted and span must be explicit. Changing calendar on a recurring event requires span: \"future\" targeting the first occurrence. " +
      "Omit fields to leave them unchanged; null clears location, notes, alarms, or recurrence. " +
      "alarms replaces all alarms; recurrence: null stops repeating. allDay: true uses yyyy-MM-dd dates with an inclusive end (2026-08-22 to 2026-08-23 = 2 days). " +
      "On timeout do not recreate: search first. " +
      "Apple カレンダーApp（macOS / iCloud）のイベントを更新する。id か ids を指定（ids は同じ変更を全件に適用）。" +
      "繰り返しは occurrence と span（\"this\"=この回だけ / \"future\"=この回以降）で対象を決める。occurrence を省略すると最初の回が対象になり、span の明示が必要。" +
      "1回だけ変更した回は id の末尾に /RID=… が付くが、シリーズの id と occurrence でも指定できる。" +
      "カレンダー移動は span: \"future\" かつ最初の回のみ。省略した項目は変更せず、null は location / notes / alarms / recurrence を消す。" +
      "allDay: true の終日は end が最終日を含む（8/22〜8/23 は2日間）。Google Calendar ではない。",
    inputSchema: {
      type: "object",
      properties: {
        ...idProps,
        ...OCCURRENCE_PROPS,
        title: { type: "string" },
        start: { type: "string", description: "開始。start だけ変えると長さを保って end もずれる" },
        end: { type: "string", description: "終了。終日なら最終日（その日を含む）" },
        allDay: { type: "boolean", description: "true / false を明示。true のとき start / end は yyyy-MM-dd" },
        calendar: { type: "string", description: "移動先カレンダー名（繰り返しは span: future の最初の回のみ）" },
        location: nullableString("null で場所を消す"),
        notes: nullableString("null でメモを消す"),
        alarms: nullableAlarms("全置換。null または [] で全削除"),
        recurrence: {
          type: ["object", "null"],
          properties: RECURRENCE_PROPERTIES,
          required: ["frequency"],
          additionalProperties: false,
          description: "null で繰り返しをやめる。start は最初の回にすること",
        },
      },
      additionalProperties: false,
    },
    buildArgs: (a) => {
      const out = ["update-event"];
      const clear: string[] = [];
      addIds(out, a);
      addOccurrence(out, a);
      addString(out, a, "title", "--title");
      addString(out, a, "start", "--start");
      addString(out, a, "end", "--end");
      addBoolValue(out, a, "allDay", "--all-day");
      addString(out, a, "calendar", "--calendar");
      addNullableString(out, clear, a, "location", "--location");
      addNullableString(out, clear, a, "notes", "--notes");
      addNullableJson(out, clear, a, "alarms", "--alarms");
      addNullableJson(out, clear, a, "recurrence", "--recurrence");
      addClear(out, clear);
      return out;
    },
  },
  {
    name: "apple_delete_event",
    title: "Apple イベントの削除",
    description:
      "Delete one or more events (appointments / schedule) from Apple Calendar on this Mac (macOS, iCloud, local, NOT Google Calendar). " +
      "Pass id or ids. For a recurring event pass occurrence and span (\"this\" default, or \"future\"); without occurrence the first occurrence is targeted and span must be explicit. occurrence cannot be combined with ids. " +
      "Deleted events are returned in full so you can recreate them manually if needed. On timeout do not assume failure; search first. " +
      "Apple カレンダーApp（macOS / iCloud）のイベントを削除する。id か ids を指定。" +
      "繰り返しは occurrence と span で対象を決め、occurrence を省略すると最初の回が対象になり span の明示が必要。" +
      "削除した内容をそのまま返すので手で復元できる。タイムアウト時は失敗と決めつけず検索で確認する。Google Calendar ではない。",
    inputSchema: {
      type: "object",
      properties: { ...idProps, ...OCCURRENCE_PROPS },
      additionalProperties: false,
    },
    annotations: { destructiveHint: true },
    buildArgs: (a) => {
      const out = ["delete-event"];
      addIds(out, a);
      addOccurrence(out, a);
      return out;
    },
  },
];

export const TOOL_NAMES = TOOLS.map((t) => t.name);

function toResult(data: Json, isError: boolean): ToolResult {
  return {
    content: [{ type: "text", text: JSON.stringify(data, null, 2) }],
    ...(isError ? { isError: true } : {}),
  };
}

function messageOf(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

function timeoutMessage(tool: ToolDef, timeoutMs: number): string {
  const secs = timeoutMs % 1000 === 0 ? `${timeoutMs / 1000}` : (timeoutMs / 1000).toFixed(1);
  return (
    `${tool.name} timed out after ${timeoutMs} ms (${secs} s) waiting for the EventKit CLI. ` +
    "The CLI may be waiting for macOS permission; check the Mac screen and System Settings > Privacy & Security > Reminders/Calendars."
  );
}

async function timeoutResult(
  tool: ToolDef,
  args: ToolArgs,
  timeoutMs: number
): Promise<ToolResult> {
  const data: Json = { error: timeoutMessage(tool, timeoutMs) };

  const isReminder = tool.name === "apple_create_reminder";
  const isEvent = tool.name === "apple_create_event";
  if (isReminder || isEvent) {
    const title = String(args.title ?? "");
    const lookup = isReminder
      ? ["search", title]
      : [
          "search-events",
          title,
          // 時刻付きだと from == to で何も引っかからないので日付単位に広げる。
          "--from",
          String(args.start ?? "").slice(0, 10),
          "--to",
          String(args.end ?? args.start ?? "").slice(0, 10),
        ];
    const key = isReminder ? "reminders" : "events";
    data.error =
      data.error +
      " Do not recreate it blindly: a follow-up search was run (10 s timeout) and any matches are in possiblyCreated. " +
      "Check them first, then retry only if nothing matches.";
    try {
      const found = await run(lookup, { timeoutMs: FOLLOW_UP_TIMEOUT_MS });
      data.possiblyCreated = Array.isArray(found[key]) ? found[key] : [];
      if (typeof found.error === "string") data.lookupError = found.error;
    } catch (e) {
      data.possiblyCreated = [];
      data.lookupError = messageOf(e);
    }
  }

  return toResult(data, true);
}

// MCP ハンドラからも単体テストからも同じ経路を通す。
export async function runTool(tool: ToolDef, args: ToolArgs): Promise<ToolResult> {
  try {
    const data = await run(tool.buildArgs(args));
    return toResult(data, typeof data.error === "string");
  } catch (e) {
    if (e instanceof CliTimeoutError) return timeoutResult(tool, args, e.timeoutMs);
    return toResult({ error: messageOf(e) }, true);
  }
}
