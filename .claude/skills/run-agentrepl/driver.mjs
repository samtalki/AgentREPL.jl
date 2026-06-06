#!/usr/bin/env node
// driver.mjs - launch and drive the AgentREPL.jl MCP server.
//
// AgentREPL is an MCP server that speaks JSON-RPC over STDIO. There is no GUI
// and no HTTP port. The only way to drive it is to be its MCP client: spawn the
// server subprocess, do the `initialize` handshake, then call its tools. That is
// exactly what this script does.
//
// Framing note: the server uses NEWLINE-DELIMITED JSON (one JSON object per
// line), NOT LSP `Content-Length:` framing. The stdout transport stays clean JSON
// (Malt workers keep their output on private pipes; the server's own logs go to
// stderr), but we still parse only lines that start with `{` defensively.
//
// Usage:
//   node driver.mjs                     # full smoke test, prints PASS/FAIL, exits non-zero on failure
//   node driver.mjs eval '<julia code>' # one eval, print the result text, exit
//   node driver.mjs call <tool> '<json>'# call any tool with a JSON args object
//   node driver.mjs repl                # interactive: each stdin line is eval'd on the worker
//
// Env:
//   JULIA_PROJECT_DIR  override the AgentREPL project dir (default: repo root, 3 levels up)
//   JULIA_BIN          julia executable (default: "julia")

import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { createInterface } from "node:readline";

const __dirname = dirname(fileURLToPath(import.meta.url));
// skill lives at <repo>/.claude/skills/run-agentrepl/, so repo root is 3 up.
const REPO_DIR = process.env.JULIA_PROJECT_DIR || resolve(__dirname, "..", "..", "..");
const JULIA = process.env.JULIA_BIN || "julia";
const SERVER = `${REPO_DIR}/bin/julia-repl-server`;

class MCPClient {
  constructor() {
    this.nextId = 1;
    this.pending = new Map(); // id -> {resolve, reject}
    this.proc = spawn(JULIA, [`--project=${REPO_DIR}`, SERVER], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.proc.on("exit", (code, sig) => {
      for (const { reject } of this.pending.values()) {
        reject(new Error(`server exited (code=${code} sig=${sig})`));
      }
      this.pending.clear();
    });
    // stdout: JSON-RPC responses interleaved with worker chatter.
    const out = createInterface({ input: this.proc.stdout });
    out.on("line", (line) => this._onLine(line));
    // stderr: @info logs + precompile noise. Mirror it dimmed so launch
    // progress is visible, but never parse it.
    const err = createInterface({ input: this.proc.stderr });
    err.on("line", (line) => process.stderr.write(`\x1b[2m[server] ${line}\x1b[0m\n`));
  }

  _onLine(line) {
    const s = line.trim();
    if (!s.startsWith("{")) return; // worker message / log line — skip
    let msg;
    try {
      msg = JSON.parse(s);
    } catch {
      return; // not a complete JSON object on one line — skip
    }
    if (msg.id != null && this.pending.has(msg.id)) {
      const { resolve, reject } = this.pending.get(msg.id);
      this.pending.delete(msg.id);
      if (msg.error) reject(new Error(JSON.stringify(msg.error)));
      else resolve(msg.result);
    }
  }

  _send(obj) {
    this.proc.stdin.write(JSON.stringify(obj) + "\n");
  }

  notify(method, params = {}) {
    this._send({ jsonrpc: "2.0", method, params });
  }

  request(method, params = {}, timeoutMs = 120000) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`timeout (${timeoutMs}ms) waiting for ${method}`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (v) => { clearTimeout(timer); resolve(v); },
        reject: (e) => { clearTimeout(timer); reject(e); },
      });
      this._send({ jsonrpc: "2.0", id, method, params });
    });
  }

  async initialize() {
    const res = await this.request("initialize", {
      capabilities: {},
      clientInfo: { name: "agentrepl-driver", version: "1.0" },
      protocolVersion: "2025-06-18",
    }, 60000);
    this.notify("notifications/initialized");
    return res;
  }

  async listTools() {
    const res = await this.request("tools/list", {}, 30000);
    return res.tools.map((t) => t.name);
  }

  // returns the first content block's text
  async callTool(name, args = {}, timeoutMs = 120000) {
    const res = await this.request("tools/call", { name, arguments: args }, timeoutMs);
    return res.content?.[0]?.text ?? JSON.stringify(res);
  }

  close() {
    try { this.proc.stdin.end(); } catch {}
    try { this.proc.kill(); } catch {}
  }
}

function ok(cond, label) {
  console.log(`${cond ? "  \x1b[32mPASS\x1b[0m" : "  \x1b[31mFAIL\x1b[0m"}  ${label}`);
  return cond;
}

async function smoke() {
  const c = new MCPClient();
  let failures = 0;
  const check = (cond, label) => { if (!ok(cond, label)) failures++; };
  try {
    const init = await c.initialize();
    check(init?.serverInfo?.name === "julia-repl", `initialize handshake (serverInfo.name=${init?.serverInfo?.name})`);

    const tools = await c.listTools();
    const expected = ["eval", "reset", "info", "pkg", "activate", "log_viewer", "session", "revise"];
    check(expected.every((t) => tools.includes(t)), `tools/list has all 8 tools (got: ${tools.join(", ")})`);

    console.log("  ... first eval spawns a worker, ~10-40s");
    const r1 = await c.callTool("eval", { code: "1 + 1" });
    check(r1.includes("2"), "eval 1+1 -> 2");

    await c.callTool("eval", { code: "_smoke_x = 42" });
    const r2 = await c.callTool("eval", { code: "_smoke_x" });
    check(r2.includes("42"), "variable persists across evals");

    const r3 = await c.callTool("eval", { code: "undefined_zzz" });
    check(r3.includes("UndefVarError"), "error surfaces (UndefVarError)");

    const r4 = await c.callTool("eval", { code: 'println("hello_driver"); 99' });
    check(r4.includes("hello_driver") && r4.includes("99"), "stdout + result both captured");

    const info = await c.callTool("info", {});
    check(info.includes("Julia Version"), "info reports Julia Version");

    const cs = await c.callTool("session", { action: "create", name: "drv-s1" });
    check(cs.includes("drv-s1"), "session create");
    const ls = await c.callTool("session", { action: "list" });
    check(ls.includes("drv-s1") && ls.includes("default"), "session list shows both");
    await c.callTool("session", { action: "destroy", name: "drv-s1" });

    const plot = await c.callTool("eval", { code: "using UnicodePlots; lineplot(1:10, (1:10).^2)" });
    check(plot.length > 0 && !plot.includes("ERROR"), "UnicodePlots renders on worker");

    await c.callTool("eval", { code: "_reset_var = 123" });
    const rst = await c.callTool("reset", {}, 60000);
    check(rst.toLowerCase().includes("reset"), "reset reports success");
    const after = await c.callTool("eval", { code: "_reset_var" });
    check(after.includes("UndefVarError"), "state cleared after reset");

    console.log(failures === 0 ? "\n\x1b[32mALL PASS\x1b[0m" : `\n\x1b[31m${failures} FAILED\x1b[0m`);
  } catch (e) {
    console.error("driver error:", e.message);
    failures++;
  } finally {
    c.close();
  }
  process.exit(failures === 0 ? 0 : 1);
}

async function oneEval(code) {
  const c = new MCPClient();
  try {
    await c.initialize();
    const text = await c.callTool("eval", { code });
    console.log(text);
  } finally {
    c.close();
  }
  process.exit(0);
}

async function oneCall(tool, jsonArgs) {
  const c = new MCPClient();
  try {
    await c.initialize();
    const args = jsonArgs ? JSON.parse(jsonArgs) : {};
    const text = await c.callTool(tool, args);
    console.log(text);
  } finally {
    c.close();
  }
  process.exit(0);
}

async function repl() {
  const c = new MCPClient();
  await c.initialize();
  console.error("\x1b[2m[driver] initialized. type Julia, one expr per line. Ctrl-D to quit.\x1b[0m");
  const rl = createInterface({ input: process.stdin, terminal: false });
  for await (const line of rl) {
    if (!line.trim()) continue;
    try {
      console.log(await c.callTool("eval", { code: line }));
    } catch (e) {
      console.error("error:", e.message);
    }
  }
  c.close();
  process.exit(0);
}

const [, , cmd, ...rest] = process.argv;
if (cmd === "eval") oneEval(rest.join(" "));
else if (cmd === "call") oneCall(rest[0], rest[1]);
else if (cmd === "repl") repl();
else smoke();
