// MCP サーバーを stdio で起動して生の JSON-RPC で叩く検証クライアント。
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const server = spawn("node", [resolve(here, "dist/index.js")], {
  stdio: ["pipe", "pipe", "pipe"],
});

server.stderr.on("data", (d) => process.stderr.write(`[server stderr] ${d}`));

let buf = "";
const pending = new Map();
server.stdout.on("data", (d) => {
  buf += d.toString("utf8");
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    const msg = JSON.parse(line);
    if (msg.id && pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    }
  }
});

let nextId = 1;
function send(method, params) {
  const id = nextId++;
  return new Promise((res) => {
    pending.set(id, res);
    server.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  });
}
function notify(method, params) {
  server.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");
}

const init = await send("initialize", {
  protocolVersion: "2025-06-18",
  capabilities: {},
  clientInfo: { name: "test", version: "1.0.0" },
});
console.log("=== initialize ===");
console.log(JSON.stringify(init.result.serverInfo), "protocol:", init.result.protocolVersion);
notify("notifications/initialized");

const tools = await send("tools/list", {});
console.log("\n=== tools/list ===");
for (const t of tools.result.tools) {
  const req = t.inputSchema.required ?? [];
  console.log(`  ${t.name.padEnd(20)} required=[${req.join(",")}]`);
}

const calls = JSON.parse(process.argv[2] ?? "[]");
for (const [name, args] of calls) {
  const r = await send("tools/call", { name, arguments: args });
  console.log(`\n=== tools/call ${name} ${JSON.stringify(args)} ===`);
  if (r.error) {
    console.log("PROTOCOL ERROR:", JSON.stringify(r.error));
  } else {
    console.log("isError:", r.result.isError ?? false);
    console.log(r.result.content[0].text);
  }
}

server.kill();
