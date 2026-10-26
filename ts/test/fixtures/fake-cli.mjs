#!/usr/bin/env node
// テスト用の偽 EventKit CLI。実物の bin/EventKitCLI.app には絶対に触らない。
// 既定では argv をそのまま JSON で返す。FAKE_CLI_MODE で挙動を変える。
const argv = process.argv.slice(2);
const mode = process.env.FAKE_CLI_MODE || "echo";

function emit(value, code = 0) {
  process.stdout.write(JSON.stringify(value) + "\n");
  process.exitCode = code;
}

function sleepForever() {
  setInterval(() => {}, 1 << 30);
}

if (mode === "sleep") {
  sleepForever();
} else if (mode === "ignore-term") {
  // SIGTERM を無視して、TS 側の SIGKILL エスカレーションを検証できるようにする。
  process.on("SIGTERM", () => {});
  sleepForever();
} else if (mode === "timeout-create") {
  // 作成だけ固まり、確認用の search / search-events には即答する。
  if (argv[0] === "search") {
    const title = argv[1] ?? "";
    emit({ query: title, count: 1, includeCompleted: false, reminders: [{ id: "r-created", title, via: argv }] });
  } else if (argv[0] === "search-events") {
    const title = argv[1] ?? "";
    emit({ query: title, from: "", to: "", count: 1, events: [{ id: "e-created", title, via: argv }] });
  } else {
    sleepForever();
  }
} else if (mode === "error") {
  emit({ error: "boom" }, 1);
} else {
  emit({ argv, accessTimeout: process.env.EVENTKIT_CLI_ACCESS_TIMEOUT ?? null });
}
