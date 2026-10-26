// E2E：本物の EventKit（iCloud のリマインダー・カレンダー）に触る。npm run test:e2e で明示的に走らせる。
// 作る項目はすべてタイトルが PREFIX で始まり、2027年の日付を使う。after() で必ず消して0件を確認する。
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const PREFIX = `[eventkit-mcp-e2e ${randomBytes(3).toString("hex")}]`;
const CAL = "自宅";
const CAL_MOVE = "職場";
const LIST = "リマインダー";
const LIST_MOVE = "買い物リスト";
const RANGE = { from: "2027-01-01", to: "2027-12-31" };

function startServer(env = {}) {
  const child = spawn(process.execPath, [resolve(here, "../dist/index.js")], {
    stdio: ["pipe", "pipe", "pipe"],
    env: { ...process.env, ...env },
  });
  let buf = "";
  let nextId = 1;
  const pending = new Map();
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, i).trim();
      buf = buf.slice(i + 1);
      if (!line) continue;
      const msg = JSON.parse(line);
      pending.get(msg.id)?.(msg);
      pending.delete(msg.id);
    }
  });
  child.stderr.resume();
  const send = (method, params) => {
    const id = nextId++;
    return new Promise((res) => {
      pending.set(id, res);
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    });
  };
  return {
    async init() {
      await send("initialize", {
        protocolVersion: "2025-06-18",
        capabilities: {},
        clientInfo: { name: "e2e", version: "1.0.0" },
      });
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
    },
    async call(name, args) {
      const r = await send("tools/call", { name, arguments: args });
      if (r.error) throw new Error(`protocol error: ${JSON.stringify(r.error)}`);
      return { isError: r.result.isError === true, data: JSON.parse(r.result.content[0].text) };
    },
    close: () => child.kill(),
  };
}

let mcp;
// 成功を前提にした呼び出し。エラーなら中身を出して落とす。
async function ok(name, args) {
  const r = await mcp.call(name, args);
  assert.equal(r.isError, false, `${name} failed: ${JSON.stringify(r.data)}`);
  return r.data;
}
async function ng(name, args) {
  const r = await mcp.call(name, args);
  assert.equal(r.isError, true, `${name} unexpectedly succeeded: ${JSON.stringify(r.data)}`);
  return r.data;
}
const t = (s) => `${PREFIX} ${s}`;
// 1回だけ変えた回は id の末尾に "/RID=…" が付く。
const inSeries = (e, id) => e.id === id || e.id.startsWith(`${id}/RID=`);

async function ourEvents(from = RANGE.from, to = RANGE.to) {
  const d = await ok("apple_search_events", { query: PREFIX, from, to });
  return d.events;
}
async function ourReminders() {
  const d = await ok("apple_search_reminders", { query: PREFIX, includeCompleted: true });
  return d.reminders;
}

before(async () => {
  mcp = startServer();
  await mcp.init();
});

after(async () => {
  // 失敗したテストが残したものも含めて全部消す。繰り返しはシリーズごと消す。
  const rs = await ourReminders();
  if (rs.length) await ok("apple_delete_reminder", { ids: rs.map((r) => r.id) });
  const seen = new Set();
  for (const e of await ourEvents()) {
    const id = e.id.split("/RID=")[0];
    if (seen.has(id)) continue;
    seen.add(id);
    await mcp.call("apple_delete_event", e.isRecurring ? { id, span: "future" } : { id });
  }
  const leftR = await ourReminders();
  const leftE = await ourEvents();
  mcp.close();
  assert.equal(leftR.length, 0, `reminders left: ${JSON.stringify(leftR)}`);
  assert.equal(leftE.length, 0, `events left: ${JSON.stringify(leftE)}`);
});

test("reminders: create / alarms / update / reopen / delete", async () => {
  const r1 = (await ok("apple_create_reminder", {
    title: t("r1"), list: LIST, due: "2027-03-10T09:00:00", priority: 5,
  })).created;
  // 時刻付き期限は既定で期限ちょうどのアラームが付く。
  assert.equal(r1.alarms.length, 1);
  assert.equal(Date.parse(r1.alarms[0].at), Date.parse(r1.due));

  const r2 = (await ok("apple_create_reminder", { title: t("r2"), list: LIST, due: "2027-03-11" })).created;
  assert.equal(r2.dueAllDay, true);
  assert.deepEqual(r2.alarms, []);

  const r3 = (await ok("apple_create_reminder", {
    title: t("r3"), list: LIST, due: "2027-03-12T10:00:00", alarms: [{ minutesBefore: 30 }],
  })).created;
  assert.equal(Date.parse(r3.due) - Date.parse(r3.alarms[0].at), 30 * 60 * 1000);

  const r4 = (await ok("apple_create_reminder", {
    title: t("r4"), list: LIST, due: "2027-03-12T10:00:00", alarms: [],
  })).created;
  assert.deepEqual(r4.alarms, []);

  // 期限のないリマインダーに相対アラームは付けられない。
  await ng("apple_create_reminder", { title: t("bad"), list: LIST, alarms: [{ minutesBefore: 5 }] });

  const up = (await ok("apple_update_reminder", {
    id: r1.id, priority: 1, list: LIST_MOVE, due: null, notes: "memo",
  })).updated[0];
  assert.equal(up.priority, 1);
  assert.equal(up.list, LIST_MOVE);
  assert.equal(up.due ?? null, null);
  assert.equal(up.notes, "memo");

  const cleared = (await ok("apple_update_reminder", { id: r1.id, notes: null, alarms: null })).updated[0];
  assert.equal(cleared.notes ?? null, null);
  assert.deepEqual(cleared.alarms, []);

  await ok("apple_complete_reminder", { id: r2.id });
  const reopened = (await ok("apple_update_reminder", { id: r2.id, completed: false })).updated[0];
  assert.equal(reopened.isCompleted, false);

  // 一括で同じ変更を当てる。
  const batch = (await ok("apple_update_reminder", { ids: [r3.id, r4.id], priority: 9 })).updated;
  assert.deepEqual(batch.map((r) => r.priority), [9, 9]);

  // 1件でも見つからなければ何も変えない。
  await ng("apple_update_reminder", { ids: [r3.id, "no-such-id"], priority: 1 });
  const after3 = (await ourReminders()).find((r) => r.id === r3.id);
  assert.equal(after3.priority, 9);

  // query 省略は全件。
  const all = await ok("apple_search_reminders", {});
  assert.ok(all.count >= 4);
  assert.equal((await ourReminders()).length, 4);

  const del = (await ok("apple_delete_reminder", { ids: [r1.id, r2.id, r3.id, r4.id] })).deleted;
  assert.equal(del.length, 4);
  assert.equal((await ourReminders()).length, 0);
});

test("events: all-day end is inclusive", async () => {
  const two = (await ok("apple_create_event", {
    title: t("2days"), calendar: CAL, start: "2027-03-01", end: "2027-03-02", allDay: true,
  })).created;
  assert.equal(two.isAllDay, true);
  assert.equal(two.start, "2027-03-01");
  assert.equal(two.end, "2027-03-02");
  // 2日目には入っていて、3日目には入っていない。
  assert.equal((await ourEvents("2027-03-02", "2027-03-02")).filter((e) => e.id === two.id).length, 1);
  assert.equal((await ourEvents("2027-03-03", "2027-03-03")).filter((e) => e.id === two.id).length, 0);

  // 日付だけの start は allDay 省略でも終日、end 省略で1日。
  const one = (await ok("apple_create_event", { title: t("1day"), calendar: CAL, start: "2027-03-05" })).created;
  assert.equal(one.isAllDay, true);
  assert.equal(one.start, "2027-03-05");
  assert.equal(one.end, "2027-03-05");
  assert.equal((await ourEvents("2027-03-06", "2027-03-06")).filter((e) => e.id === one.id).length, 0);

  // start だけずらすと日数を保つ。
  const moved = (await ok("apple_update_event", { id: two.id, start: "2027-03-08" })).updated[0];
  assert.equal(moved.start, "2027-03-08");
  assert.equal(moved.end, "2027-03-09");

  await ok("apple_delete_event", { ids: [two.id, one.id] });
});

test("events: timed update keeps duration, clears fields, alarms", async () => {
  const e = (await ok("apple_create_event", {
    title: t("timed"), calendar: CAL, start: "2027-03-15T10:00:00", end: "2027-03-15T11:00:00",
    location: "X", alarms: [{ minutesBefore: 10 }, { at: "2027-03-15T08:00:00" }],
  })).created;
  assert.equal(e.isAllDay, false);
  assert.equal(e.alarms.length, 2);
  assert.ok(e.alarms.some((a) => a.minutesBefore === 10));
  assert.ok(e.alarms.some((a) => a.at && Date.parse(a.at) === Date.parse("2027-03-15T08:00:00")));

  const up = (await ok("apple_update_event", {
    id: e.id, start: "2027-03-15T13:00:00", location: null, alarms: [],
  })).updated[0];
  assert.equal(Date.parse(up.end) - Date.parse(up.start), 60 * 60 * 1000);
  assert.equal(Date.parse(up.start), Date.parse("2027-03-15T13:00:00"));
  assert.equal(up.location ?? null, null);
  assert.deepEqual(up.alarms, []);

  // 繰り返しでないイベントに occurrence は渡せない。
  await ng("apple_update_event", { id: e.id, occurrence: e.occurrence, title: "x" });

  await ok("apple_delete_event", { id: e.id });
  assert.equal((await ourEvents("2027-03-15", "2027-03-15")).length, 0);
});

test("events: recurrence, exclude, occurrence/span, calendar move", async () => {
  // 2027-04-05 は月曜。月・木の毎週、4/30 まで。4/8 は休み、4/20(火) は該当なし。
  const created = await ok("apple_create_event", {
    title: t("weekly"), calendar: CAL, start: "2027-04-05T10:00:00", end: "2027-04-05T11:30:00",
    recurrence: { frequency: "weekly", daysOfWeek: ["mon", "thu"], until: "2027-04-30" },
    exclude: ["2027-04-08", "2027-04-20"],
    alarms: [{ minutesBefore: 15 }],
  });
  assert.deepEqual(created.excludeNotFound, ["2027-04-20"]);
  const w = created.created;
  assert.equal(w.isRecurring, true);
  assert.equal(w.recurrence.frequency, "weekly");
  assert.deepEqual([...w.recurrence.daysOfWeek].sort(), ["mon", "thu"]);
  assert.equal(w.recurrence.until, "2027-04-30");

  const april = () => ourEvents("2027-04-01", "2027-04-30");
  let occ = (await april()).filter((e) => inSeries(e, w.id));
  // 4/5,12,15,19,22,26,29（4/8 を除外）
  assert.deepEqual(occ.map((e) => e.start.slice(0, 10)),
    ["2027-04-05", "2027-04-12", "2027-04-15", "2027-04-19", "2027-04-22", "2027-04-26", "2027-04-29"]);
  assert.ok(occ.every((e) => e.alarms.some((a) => a.minutesBefore === 15)));

  // start の曜日が daysOfWeek に無いのはエラー。
  await ng("apple_create_event", {
    title: t("bad"), calendar: CAL, start: "2027-04-06T10:00:00", end: "2027-04-06T11:00:00",
    recurrence: { frequency: "weekly", daysOfWeek: ["mon"] },
  });

  // 繰り返しで occurrence も span も無いのはエラー。
  await ng("apple_update_event", { id: w.id, title: t("x") });

  // 1回だけ変える。
  const apr12 = occ.find((e) => e.start.startsWith("2027-04-12"));
  await ok("apple_update_event", { id: w.id, occurrence: apr12.occurrence, span: "this", title: t("weekly-changed") });
  occ = (await april()).filter((e) => inSeries(e, w.id));
  assert.deepEqual(occ.filter((e) => e.title === t("weekly-changed")).map((e) => e.start.slice(0, 10)), ["2027-04-12"]);
  assert.equal(occ.filter((e) => e.title === t("weekly")).length, 6);
  // 変更済みの回もシリーズの id + occurrence で指定できる。
  const changed = occ.find((e) => e.title === t("weekly-changed"));
  await ok("apple_update_event", { id: w.id, occurrence: changed.occurrence, span: "this", location: "Room 2" });
  occ = (await april()).filter((e) => inSeries(e, w.id));
  assert.equal(occ.find((e) => e.start.startsWith("2027-04-12")).location, "Room 2");

  // 4/22 以降を削除。
  const apr22 = occ.find((e) => e.start.startsWith("2027-04-22"));
  const del = (await ok("apple_delete_event", { id: w.id, occurrence: apr22.occurrence, span: "future" })).deleted;
  assert.equal(del.length, 1);
  occ = (await april()).filter((e) => inSeries(e, w.id));
  assert.deepEqual(occ.map((e) => e.start.slice(0, 10)), ["2027-04-05", "2027-04-12", "2027-04-15", "2027-04-19"]);

  // 隔週・回数指定。
  const b = (await ok("apple_create_event", {
    title: t("biweekly"), calendar: CAL, start: "2027-05-03T09:00:00", end: "2027-05-03T10:00:00",
    recurrence: { frequency: "weekly", interval: 2, count: 3 },
  })).created;
  assert.equal(b.recurrence.interval, 2);
  assert.equal(b.recurrence.count, 3);
  const may = async () => (await ourEvents("2027-05-01", "2027-06-30")).filter((e) => inSeries(e, b.id));
  assert.deepEqual((await may()).map((e) => e.start.slice(0, 10)), ["2027-05-03", "2027-05-17", "2027-05-31"]);

  // カレンダー移動は span: future で最初の回のときだけ。
  const second = (await may())[1];
  await ng("apple_update_event", { id: b.id, occurrence: second.occurrence, span: "this", calendar: CAL_MOVE });
  await ok("apple_update_event", { id: b.id, span: "future", calendar: CAL_MOVE });
  assert.deepEqual((await may()).map((e) => e.calendar), [CAL_MOVE, CAL_MOVE, CAL_MOVE]);

  // 繰り返しをやめる。
  const stopped = (await ok("apple_update_event", { id: b.id, span: "future", recurrence: null })).updated[0];
  assert.equal(stopped.isRecurring, false);
  assert.equal((await may()).length, 1);

  await ok("apple_delete_event", { id: w.id, span: "future" });
  await ok("apple_delete_event", { id: b.id });
  assert.equal((await ourEvents("2027-04-01", "2027-06-30")).length, 0);
});

test("timeout returns isError instead of hanging", async () => {
  const slow = startServer({ EVENTKIT_MCP_TIMEOUT_MS: "1" });
  await slow.init();
  try {
    const r = await slow.call("apple_reminder_lists", {});
    assert.equal(r.isError, true);
    assert.match(r.data.error, /timed out/);
  } finally {
    slow.close();
  }
});
