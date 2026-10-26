import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const FAKE = resolve(here, "fixtures/fake-cli.mjs");

const EXPECTED_TOOLS = [
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
];

const READ_ONLY = [
  "apple_reminder_lists",
  "apple_reminders",
  "apple_search_reminders",
  "apple_calendars",
  "apple_events",
  "apple_search_events",
];

const DESTRUCTIVE = ["apple_delete_reminder", "apple_delete_event"];

function startServer() {
  const child = spawn(process.execPath, [resolve(here, "../dist/index.js")], {
    stdio: ["pipe", "pipe", "pipe"],
    env: {
      ...process.env,
      EVENTKIT_CLI_BIN: FAKE,
      FAKE_CLI_MODE: "echo",
      EVENTKIT_MCP_TIMEOUT_MS: "45000",
    },
  });

  let buffer = "";
  let stderr = "";
  const pending = new Map();
  let nextId = 1;

  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    buffer += chunk;
    let i;
    while ((i = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, i).trim();
      buffer = buffer.slice(i + 1);
      if (!line) continue;
      const msg = JSON.parse(line);
      if (msg.id === undefined || !pending.has(msg.id)) continue;
      const { resolve: resolvePromise, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) reject(new Error(`JSON-RPC error: ${JSON.stringify(msg.error)}`));
      else resolvePromise(msg.result);
    }
  });
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });

  function send(method, params) {
    const id = nextId++;
    return new Promise((resolvePromise, reject) => {
      pending.set(id, { resolve: resolvePromise, reject });
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    });
  }

  function notify(method, params) {
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");
  }

  async function initialize() {
    const result = await send("initialize", {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "test", version: "1.0.0" },
    });
    notify("notifications/initialized");
    return result;
  }

  async function stop() {
    if (child.exitCode === null) child.kill("SIGTERM");
    await once(child, "close");
  }

  return {
    send,
    initialize,
    stop,
    stderr: () => stderr,
  };
}

test("tools/list exposes exactly 13 apple_ tools with annotations", async () => {
  const server = startServer();
  try {
    const init = await server.initialize();
    assert.equal(init.serverInfo.name, "eventkit-mcp");
    assert.equal(init.serverInfo.version, "2.0.0");

    const { tools } = await server.send("tools/list", {});
    assert.deepEqual(tools.map((t) => t.name), EXPECTED_TOOLS);
    assert.equal(tools.length, 13);

    const byName = Object.fromEntries(tools.map((t) => [t.name, t]));
    for (const name of READ_ONLY) {
      assert.equal(byName[name].annotations?.readOnlyHint, true, `${name} should be readOnly`);
    }
    for (const name of DESTRUCTIVE) {
      assert.equal(byName[name].annotations?.destructiveHint, true, `${name} should be destructive`);
    }
    assert.notEqual(byName.apple_create_event.annotations?.readOnlyHint, true);
    assert.notEqual(byName.apple_update_event.annotations?.readOnlyHint, true);

    // 検索系は query 省略可、期間取得は from/to 必須。
    assert.equal(byName.apple_search_reminders.inputSchema.required?.includes("query") ?? false, false);
    assert.equal(byName.apple_search_events.inputSchema.required?.includes("query") ?? false, false);
    assert.deepEqual(byName.apple_events.inputSchema.required, ["from", "to"]);
  } finally {
    await server.stop();
  }
});

test("tools/call passes the expected argv to the fake CLI", async () => {
  const server = startServer();
  try {
    await server.initialize();

    const recurrence = {
      frequency: "weekly",
      interval: 2,
      daysOfWeek: ["mon", "thu"],
      until: "2026-12-31",
    };
    const alarms = [{ minutesBefore: 10 }];
    const exclude = ["2026-09-07"];
    const createArgs = {
      title: "Team sync",
      start: "2026-08-22",
      end: "2026-08-23",
      allDay: true,
      calendar: "自宅",
      location: "会議室",
      notes: "メモ",
      alarms,
      recurrence,
      exclude,
    };

    const created = await server.send("tools/call", {
      name: "apple_create_event",
      arguments: createArgs,
    });
    assert.equal(created.isError ?? false, false);
    assert.deepEqual(JSON.parse(created.content[0].text).argv, [
      "create-event", "--title", "Team sync", "--start", "2026-08-22",
      "--end", "2026-08-23", "--calendar", "自宅", "--location", "会議室",
      "--notes", "メモ", "--all-day",
      "--alarms", JSON.stringify(alarms),
      "--recurrence", JSON.stringify(recurrence),
      "--exclude", JSON.stringify(exclude),
    ]);

    const updated = await server.send("tools/call", {
      name: "apple_update_reminder",
      arguments: { id: "r1", due: null, notes: null, alarms: null, completed: false },
    });
    assert.equal(updated.isError ?? false, false);
    assert.deepEqual(JSON.parse(updated.content[0].text).argv, [
      "update-reminder", "--id", "r1", "--completed", "false",
      "--clear", "due,notes,alarms",
    ]);

    const searched = await server.send("tools/call", {
      name: "apple_search_reminders",
      arguments: {},
    });
    assert.equal(searched.isError ?? false, false);
    assert.deepEqual(JSON.parse(searched.content[0].text).argv, ["search"]);
  } finally {
    await server.stop();
  }
});
