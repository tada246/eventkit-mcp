import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

export const DEFAULT_TIMEOUT_MS = 45_000;
export const TIMEOUT_KILL_GRACE_MS = 2_000;
// 権限待ちは TS 側のタイムアウトより短くする（設計 4.2）。
export const ACCESS_TIMEOUT_SECONDS = 30;

const DEFAULT_BIN = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../../bin/EventKitCLI.app/Contents/MacOS/eventkit-cli"
);

export type Json = Record<string, unknown>;

export class CliTimeoutError extends Error {
  readonly timeoutMs: number;

  constructor(timeoutMs: number) {
    super(`eventkit-cli timed out after ${timeoutMs} ms (${seconds(timeoutMs)})`);
    this.name = "CliTimeoutError";
    this.timeoutMs = timeoutMs;
  }
}

function seconds(ms: number): string {
  return ms % 1000 === 0 ? `${ms / 1000} s` : `${(ms / 1000).toFixed(1)} s`;
}

export function cliBin(): string {
  return process.env.EVENTKIT_CLI_BIN || DEFAULT_BIN;
}

export function cliTimeoutMs(): number {
  const raw = process.env.EVENTKIT_MCP_TIMEOUT_MS;
  if (!raw) return DEFAULT_TIMEOUT_MS;
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? n : DEFAULT_TIMEOUT_MS;
}

// stdio トランスポートは stdout を占有するので、子プロセスの stdout は
// 必ず pipe で受ける（inherit にするとプロトコルが壊れて無言でハングする）。
export function run(args: string[], opts: { timeoutMs?: number } = {}): Promise<Json> {
  const timeoutMs = opts.timeoutMs ?? cliTimeoutMs();
  return new Promise((resolvePromise, reject) => {
    const child = spawn(cliBin(), args, {
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, EVENTKIT_CLI_ACCESS_TIMEOUT: String(ACCESS_TIMEOUT_SECONDS) },
    });
    // マルチバイト文字が chunk 境界で割れるので Buffer を連結してから decode する。
    const out: Buffer[] = [];
    const err: Buffer[] = [];
    child.stdout.on("data", (d: Buffer) => out.push(d));
    child.stderr.on("data", (d: Buffer) => err.push(d));

    let settled = false;
    let timedOut = false;
    let killTimer: NodeJS.Timeout | undefined;

    const finish = (fn: () => void) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (killTimer) clearTimeout(killTimer);
      fn();
    };

    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
      // SIGTERM を無視する子プロセスも確実に終わらせる。
      killTimer = setTimeout(() => child.kill("SIGKILL"), TIMEOUT_KILL_GRACE_MS);
    }, timeoutMs);

    child.on("error", (e) => finish(() => reject(e)));
    child.on("close", () => {
      finish(() => {
        if (timedOut) {
          reject(new CliTimeoutError(timeoutMs));
          return;
        }
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
  });
}
