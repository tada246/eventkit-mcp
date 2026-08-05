#!/usr/bin/env node
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { McpServer, fromJsonSchema } from "@modelcontextprotocol/server";
import { serveStdio } from "@modelcontextprotocol/server/stdio";

const BIN = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../../bin/EventKitCLI.app/Contents/MacOS/eventkit-cli"
);

type Json = Record<string, unknown>;

// stdio トランスポートは stdout を占有するので、子プロセスの stdout は
// 必ず pipe で受ける（inherit にするとプロトコルが壊れて無言でハングする）。
function run(args: string[]): Promise<Json> {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(BIN, args, {
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, EVENTKIT_CLI_ACCESS_TIMEOUT: "120" },
    });
    // マルチバイト文字が chunk 境界で割れるので Buffer を連結してから decode する。
    const out: Buffer[] = [];
    const err: Buffer[] = [];
    child.stdout.on("data", (d: Buffer) => out.push(d));
    child.stderr.on("data", (d: Buffer) => err.push(d));
    child.on("error", reject);
    child.on("close", () => {
      const text = Buffer.concat(out).toString("utf8");
      const stderr = Buffer.concat(err).toString("utf8");
      if (stderr.trim()) console.error(`[eventkit-cli] ${stderr.trim()}`);
      try {
        resolvePromise(JSON.parse(text) as Json);
      } catch {
        reject(new Error(`invalid JSON from eventkit-cli: ${text.slice(0, 500)}`));
      }
    });
  });
}

async function call(args: string[]) {
  const data = await run(args);
  const isError = typeof data.error === "string";
  return {
    content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }],
    ...(isError ? { isError: true } : {}),
  };
}

function flags(o: Record<string, unknown>, map: Record<string, string>): string[] {
  const args: string[] = [];
  for (const [key, flag] of Object.entries(map)) {
    const v = o[key];
    if (v === undefined || v === null || v === "") continue;
    if (typeof v === "boolean") {
      if (v) args.push(flag);
    } else {
      args.push(flag, String(v));
    }
  }
  return args;
}

const handle = serveStdio(() => {
  const server = new McpServer({ name: "eventkit-mcp", version: "1.0.0" });

  server.registerTool(
    "reminder_lists",
    {
      title: "リマインダーのリスト一覧",
      description:
        "Apple リマインダーApp のリスト一覧（名前とID）を全部返す。 " +
        "List all reminder lists in the macOS Reminders app (Apple Reminders, local, not Google Tasks).",
      inputSchema: fromJsonSchema<{}>({ type: "object", properties: {}, additionalProperties: false }),
    },
    async () => call(["lists"])
  );

  server.registerTool(
    "reminders",
    {
      title: "リマインダーの取得",
      description:
        "Apple リマインダーApp のリマインダー(todo)を取得する。list を指定するとそのリスト、省略すると全リスト。既定は未完了のみ。 " +
        "Get reminders / todos / tasks from the macOS Reminders app (Apple Reminders). Omit list to fetch every list.",
      inputSchema: fromJsonSchema<{ list?: string; includeCompleted?: boolean }>({
        type: "object",
        properties: {
          list: { type: "string", description: "リスト名。省略すると全リスト" },
          includeCompleted: { type: "boolean", description: "完了済みも含める（既定 false）" },
        },
        additionalProperties: false,
      }),
    },
    async ({ list, includeCompleted }) =>
      call([
        "reminders",
        ...(list ? ["--list", list] : ["--all"]),
        ...(includeCompleted ? ["--include-completed"] : []),
      ])
  );

  server.registerTool(
    "search_reminders",
    {
      title: "リマインダーの検索",
      description:
        "Apple リマインダーApp を名前とメモで検索する。大文字小文字と日本語の正規化揺れを無視する。 " +
        "Search reminders / todos by title and notes in the macOS Reminders app (Apple Reminders).",
      inputSchema: fromJsonSchema<{ query: string; list?: string; includeCompleted?: boolean }>({
        type: "object",
        properties: {
          query: { type: "string", description: "検索文字列" },
          list: { type: "string", description: "検索対象のリスト名（省略で全リスト）" },
          includeCompleted: { type: "boolean" },
        },
        required: ["query"],
        additionalProperties: false,
      }),
    },
    async ({ query, list, includeCompleted }) =>
      call([
        "search",
        query,
        ...flags({ list }, { list: "--list" }),
        ...(includeCompleted ? ["--include-completed"] : []),
      ])
  );

  server.registerTool(
    "create_reminder",
    {
      title: "リマインダーの作成",
      description:
        "Apple リマインダーApp にリマインダーを作成する。due は 2026-08-10 なら終日、2026-08-10T15:30:00 なら時刻付き。 " +
        "Create a reminder / todo in the macOS Reminders app (Apple Reminders).",
      inputSchema: fromJsonSchema<{
        title: string; list?: string; due?: string; notes?: string; priority?: number;
      }>({
        type: "object",
        properties: {
          title: { type: "string" },
          list: { type: "string", description: "省略すると既定のリスト" },
          due: { type: "string", description: "yyyy-MM-dd（終日）または yyyy-MM-ddTHH:mm:ss" },
          notes: { type: "string" },
          priority: {
            type: "integer", minimum: 0, maximum: 9,
            description: "0=なし, 1-4=高, 5=中, 6-9=低",
          },
        },
        required: ["title"],
        additionalProperties: false,
      }),
    },
    async (a) =>
      call([
        "create-reminder",
        ...flags(a, { title: "--title", list: "--list", due: "--due", notes: "--notes", priority: "--priority" }),
      ])
  );

  server.registerTool(
    "complete_reminder",
    {
      title: "リマインダーを完了にする",
      description:
        "Apple リマインダーApp のリマインダーを ID 指定で完了にする。ID は reminders / search_reminders で取れる。 " +
        "Mark a reminder / todo as completed (done) in the macOS Reminders app.",
      inputSchema: fromJsonSchema<{ id: string }>({
        type: "object",
        properties: { id: { type: "string" } },
        required: ["id"],
        additionalProperties: false,
      }),
    },
    async ({ id }) => call(["complete-reminder", id])
  );

  server.registerTool(
    "calendars",
    {
      title: "カレンダー一覧",
      description:
        "Apple カレンダーApp のカレンダー一覧を返す。allowsModify が false のものは書き込み不可。 " +
        "List local macOS Calendar.app calendars (Apple Calendar / iCloud, NOT Google Calendar).",
      inputSchema: fromJsonSchema<{}>({ type: "object", properties: {}, additionalProperties: false }),
    },
    async () => call(["calendars"])
  );

  server.registerTool(
    "events",
    {
      title: "イベントの取得",
      description:
        "Apple カレンダーApp の期間内イベント(予定/スケジュール)を取得する。4年を超える期間も内部で分割して全件返す。 " +
        "Get events / appointments / schedule for a date range from the macOS Calendar.app (Apple Calendar, NOT Google Calendar).",
      inputSchema: fromJsonSchema<{ from: string; to: string; calendar?: string }>({
        type: "object",
        properties: {
          from: { type: "string", description: "yyyy-MM-dd または ISO8601" },
          to: { type: "string", description: "yyyy-MM-dd または ISO8601" },
          calendar: { type: "string", description: "カレンダー名（省略で全部）" },
        },
        required: ["from", "to"],
        additionalProperties: false,
      }),
    },
    async (a) => call(["events", ...flags(a, { from: "--from", to: "--to", calendar: "--calendar" })])
  );

  server.registerTool(
    "search_events",
    {
      title: "イベントの検索",
      description:
        "Apple カレンダーApp のイベントをタイトル・場所・メモで検索する。期間を省略すると前1年〜後2年。 " +
        "Search events / appointments in the macOS Calendar.app by title, location and notes.",
      inputSchema: fromJsonSchema<{ query: string; from?: string; to?: string }>({
        type: "object",
        properties: {
          query: { type: "string" },
          from: { type: "string" },
          to: { type: "string" },
        },
        required: ["query"],
        additionalProperties: false,
      }),
    },
    async ({ query, from, to }) =>
      call(["search-events", query, ...flags({ from, to }, { from: "--from", to: "--to" })])
  );

  server.registerTool(
    "create_event",
    {
      title: "イベントの作成",
      description:
        "Apple カレンダーApp にイベント(予定)を作成する。allDay を true にすると終日。 " +
        "Create an event / appointment in the macOS Calendar.app (Apple Calendar).",
      inputSchema: fromJsonSchema<{
        title: string; start: string; end: string;
        calendar?: string; location?: string; notes?: string; allDay?: boolean;
      }>({
        type: "object",
        properties: {
          title: { type: "string" },
          start: { type: "string", description: "yyyy-MM-dd または yyyy-MM-ddTHH:mm:ss" },
          end: { type: "string" },
          calendar: { type: "string", description: "省略すると既定のカレンダー" },
          location: { type: "string" },
          notes: { type: "string" },
          allDay: { type: "boolean" },
        },
        required: ["title", "start", "end"],
        additionalProperties: false,
      }),
    },
    async (a) =>
      call([
        "create-event",
        ...flags(a, {
          title: "--title", start: "--start", end: "--end",
          calendar: "--calendar", location: "--location", notes: "--notes", allDay: "--all-day",
        }),
      ])
  );

  return server;
});

process.on("SIGINT", () => void handle.close());
console.error(`eventkit-mcp listening on stdio (binary: ${BIN})`);
