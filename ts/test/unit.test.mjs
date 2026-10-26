import { test } from "node:test";
import assert from "node:assert/strict";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { TOOLS, TOOL_NAMES, runTool } from "../dist/tools.js";
import { run } from "../dist/cli.js";

const here = dirname(fileURLToPath(import.meta.url));
const FAKE = resolve(here, "fixtures/fake-cli.mjs");

// どのテストも本物の bin/EventKitCLI.app を起動しない。
process.env.EVENTKIT_CLI_BIN = FAKE;
delete process.env.EVENTKIT_MCP_TIMEOUT_MS;

function tool(name) {
  const found = TOOLS.find((t) => t.name === name);
  assert.ok(found, `missing tool: ${name}`);
  return found;
}

function build(name, args) {
  return tool(name).buildArgs(args);
}

test("exports exactly the 13 apple_ prefixed tools", () => {
  assert.deepEqual(TOOL_NAMES, [
    "apple_reminder_lists",
    "apple_reminders",
    "apple_search_reminders",
    "apple_create_reminder",
    "apple_update_reminder",
    "apple_complete_reminder",
    "apple_delete_reminder",
    "apple_calendars",
    "apple_events",
    "apple_search_events",
    "apple_create_event",
    "apple_update_event",
    "apple_delete_event",
  ]);
});

test("read tools map arguments to CLI flags", () => {
  assert.deepEqual(build("apple_reminder_lists", {}), ["lists"]);

  assert.deepEqual(build("apple_reminders", { list: "買い物" }), ["reminders", "--list", "買い物"]);
  assert.deepEqual(build("apple_reminders", { includeCompleted: true }), [
    "reminders", "--all", "--include-completed",
  ]);

  assert.deepEqual(build("apple_search_reminders", {}), ["search"]);
  assert.deepEqual(build("apple_search_reminders", { query: "" }), ["search"]);
  assert.deepEqual(
    build("apple_search_reminders", { query: "牛乳", list: "買い物", includeCompleted: true }),
    ["search", "牛乳", "--list", "買い物", "--include-completed"]
  );

  assert.deepEqual(build("apple_calendars", {}), ["calendars"]);

  assert.deepEqual(
    build("apple_events", { from: "2026-08-10", to: "2026-08-11", calendar: "自宅" }),
    ["events", "--from", "2026-08-10", "--to", "2026-08-11", "--calendar", "自宅"]
  );

  assert.deepEqual(build("apple_search_events", {}), ["search-events"]);
  assert.deepEqual(build("apple_search_events", { query: "" }), ["search-events"]);
  assert.deepEqual(
    build("apple_search_events", { query: "会議", from: "2026-08-10", to: "2026-08-11" }),
    ["search-events", "会議", "--from", "2026-08-10", "--to", "2026-08-11"]
  );
});

test("reminder writes map arguments, ids, alarms and null clears", () => {
  assert.deepEqual(
    build("apple_create_reminder", {
      title: "牛乳",
      list: "買い物",
      due: "2026-08-10T15:30:00",
      notes: "2本",
      priority: 5,
      alarms: [{ minutesBefore: 30 }],
    }),
    [
      "create-reminder", "--title", "牛乳", "--list", "買い物",
      "--due", "2026-08-10T15:30:00", "--notes", "2本", "--priority", "5",
      "--alarms", '[{"minutesBefore":30}]',
    ]
  );

  assert.deepEqual(build("apple_complete_reminder", { id: "r1" }), ["complete-reminder", "r1"]);

  assert.deepEqual(build("apple_delete_reminder", { ids: ["r1", "r2"] }), [
    "delete-reminder", "--ids", '["r1","r2"]',
  ]);

  assert.deepEqual(
    build("apple_update_reminder", {
      id: "r1",
      title: "牛乳",
      list: "買い物",
      due: null,
      notes: null,
      priority: 2,
      alarms: null,
      completed: false,
    }),
    [
      "update-reminder", "--id", "r1", "--title", "牛乳", "--list", "買い物",
      "--priority", "2", "--completed", "false", "--clear", "due,notes,alarms",
    ]
  );

  assert.deepEqual(
    build("apple_update_reminder", { ids: ["r1", "r2"], completed: true }),
    ["update-reminder", "--ids", '["r1","r2"]', "--completed", "true"]
  );

  assert.deepEqual(build("apple_update_reminder", { id: "r1", alarms: [] }), [
    "update-reminder", "--id", "r1", "--alarms", "[]",
  ]);
});

test("event writes map arguments, allDay forms, JSON and null clears", () => {
  const recurrence = {
    frequency: "weekly",
    interval: 2,
    daysOfWeek: ["mon", "thu"],
    until: "2026-12-31",
  };
  assert.deepEqual(
    build("apple_create_event", {
      title: "定例",
      start: "2026-08-22",
      end: "2026-08-23",
      calendar: "自宅",
      location: "会議室",
      notes: "メモ",
      allDay: true,
      alarms: [{ at: "2026-08-22T08:00:00" }],
      recurrence,
      exclude: ["2026-09-07"],
    }),
    [
      "create-event", "--title", "定例", "--start", "2026-08-22", "--end", "2026-08-23",
      "--calendar", "自宅", "--location", "会議室", "--notes", "メモ", "--all-day",
      "--alarms", '[{"at":"2026-08-22T08:00:00"}]',
      "--recurrence", '{"frequency":"weekly","interval":2,"daysOfWeek":["mon","thu"],"until":"2026-12-31"}',
      "--exclude", '["2026-09-07"]',
    ]
  );

  // 作成時の allDay: false はフラグを付けない（日時から自動判定）。
  assert.deepEqual(
    build("apple_create_event", {
      title: "打合せ",
      start: "2026-08-10T10:00:00",
      end: "2026-08-10T11:00:00",
      allDay: false,
    }),
    [
      "create-event", "--title", "打合せ", "--start", "2026-08-10T10:00:00",
      "--end", "2026-08-10T11:00:00",
    ]
  );

  // 更新時は allDay を true / false の両方で明示する。
  assert.deepEqual(
    build("apple_update_event", {
      ids: ["e1", "e2"],
      occurrence: "2026-08-24T09:00:00",
      span: "future",
      title: "定例",
      start: "2026-08-24T09:00:00",
      end: "2026-08-24T10:00:00",
      allDay: false,
      calendar: "職場",
      location: null,
      notes: null,
      alarms: [],
      recurrence: null,
    }),
    [
      "update-event", "--ids", '["e1","e2"]', "--occurrence", "2026-08-24T09:00:00",
      "--span", "future", "--title", "定例", "--start", "2026-08-24T09:00:00",
      "--end", "2026-08-24T10:00:00", "--all-day", "false", "--calendar", "職場",
      "--alarms", "[]", "--clear", "location,notes,recurrence",
    ]
  );

  assert.deepEqual(
    build("apple_update_event", {
      id: "e1",
      allDay: true,
      recurrence: { frequency: "daily" },
    }),
    [
      "update-event", "--id", "e1", "--all-day", "true",
      "--recurrence", '{"frequency":"daily"}',
    ]
  );

  assert.deepEqual(
    build("apple_delete_event", {
      id: "e1",
      occurrence: "2026-08-24T09:00:00",
      span: "this",
    }),
    [
      "delete-event", "--id", "e1", "--occurrence", "2026-08-24T09:00:00",
      "--span", "this",
    ]
  );
  assert.deepEqual(build("apple_delete_event", { ids: ["e1", "e2"] }), [
    "delete-event", "--ids", '["e1","e2"]',
  ]);
});

test("passes EVENTKIT_CLI_ACCESS_TIMEOUT=30 and pipes the fake argv", async () => {
  process.env.FAKE_CLI_MODE = "echo";
  try {
    const data = await run(["events", "--from", "2026-08-10", "--to", "2026-08-11"]);
    assert.deepEqual(data.argv, ["events", "--from", "2026-08-10", "--to", "2026-08-11"]);
    assert.equal(data.accessTimeout, "30");
  } finally {
    delete process.env.FAKE_CLI_MODE;
  }
});

test("timeout kills the child and returns isError with the duration", async () => {
  process.env.FAKE_CLI_MODE = "sleep";
  process.env.EVENTKIT_MCP_TIMEOUT_MS = "300";
  try {
    const started = Date.now();
    const res = await runTool(tool("apple_reminders"), {});
    const elapsed = Date.now() - started;

    assert.equal(res.isError, true);
    assert.match(res.content[0].text, /timed out after 300 ms/);
    assert.ok(elapsed >= 250, `returned too early: ${elapsed} ms`);
    assert.ok(elapsed < 5_000, `returned too late: ${elapsed} ms`);
  } finally {
    delete process.env.FAKE_CLI_MODE;
    delete process.env.EVENTKIT_MCP_TIMEOUT_MS;
  }
});

test("timeout escalates to SIGKILL when the child ignores SIGTERM", async () => {
  process.env.FAKE_CLI_MODE = "ignore-term";
  process.env.EVENTKIT_MCP_TIMEOUT_MS = "100";
  try {
    const started = Date.now();
    const res = await runTool(tool("apple_reminders"), {});
    const elapsed = Date.now() - started;

    assert.equal(res.isError, true);
    assert.ok(elapsed >= 2_000, `SIGKILL escalation was too fast: ${elapsed} ms`);
    assert.ok(elapsed < 6_000, `SIGKILL escalation was too slow: ${elapsed} ms`);
  } finally {
    delete process.env.FAKE_CLI_MODE;
    delete process.env.EVENTKIT_MCP_TIMEOUT_MS;
  }
});

test("create reminder timeout runs one search lookup and returns possiblyCreated", async () => {
  process.env.FAKE_CLI_MODE = "timeout-create";
  process.env.EVENTKIT_MCP_TIMEOUT_MS = "300";
  try {
    const res = await runTool(tool("apple_create_reminder"), { title: "牛乳" });
    assert.equal(res.isError, true);

    const data = JSON.parse(res.content[0].text);
    assert.match(data.error, /timed out after 300 ms/);
    assert.match(data.error, /Do not recreate/);
    assert.equal(data.possiblyCreated.length, 1);
    assert.equal(data.possiblyCreated[0].title, "牛乳");
    assert.deepEqual(data.possiblyCreated[0].via, ["search", "牛乳"]);
  } finally {
    delete process.env.FAKE_CLI_MODE;
    delete process.env.EVENTKIT_MCP_TIMEOUT_MS;
  }
});

test("create event timeout searches by title and start/end", async () => {
  process.env.FAKE_CLI_MODE = "timeout-create";
  process.env.EVENTKIT_MCP_TIMEOUT_MS = "300";
  try {
    const res = await runTool(tool("apple_create_event"), {
      title: "定例",
      start: "2026-08-22",
      end: "2026-08-23",
    });
    assert.equal(res.isError, true);

    const data = JSON.parse(res.content[0].text);
    assert.equal(data.possiblyCreated.length, 1);
    assert.deepEqual(data.possiblyCreated[0].via, [
      "search-events", "定例", "--from", "2026-08-22", "--to", "2026-08-23",
    ]);

    // end を省略した単日終日は --to に start を使う。
    const single = await runTool(tool("apple_create_event"), {
      title: "単日",
      start: "2026-08-22",
    });
    const singleData = JSON.parse(single.content[0].text);
    assert.deepEqual(singleData.possiblyCreated[0].via, [
      "search-events", "単日", "--from", "2026-08-22", "--to", "2026-08-22",
    ]);

    // 時刻付きは日付単位に広げる（from == to だと何も見つからない）。
    const timed = await runTool(tool("apple_create_event"), {
      title: "会議",
      start: "2026-08-22T10:00:00",
      end: "2026-08-22T11:00:00",
    });
    const timedData = JSON.parse(timed.content[0].text);
    assert.deepEqual(timedData.possiblyCreated[0].via, [
      "search-events", "会議", "--from", "2026-08-22", "--to", "2026-08-22",
    ]);
  } finally {
    delete process.env.FAKE_CLI_MODE;
    delete process.env.EVENTKIT_MCP_TIMEOUT_MS;
  }
});

// Claude の API はツール入力スキーマ最上位の anyOf / oneOf / allOf を受け付けない。
test("no tool schema uses top-level anyOf / oneOf / allOf", () => {
  for (const t of TOOLS) {
    for (const k of ["anyOf", "oneOf", "allOf"]) {
      assert.equal(k in t.inputSchema, false, `${t.name} has top-level ${k}`);
    }
    assert.equal(t.inputSchema.type, "object", t.name);
  }
});
