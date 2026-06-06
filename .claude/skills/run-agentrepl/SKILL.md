---
name: run-agentrepl
description: Build, run, and drive the AgentREPL.jl MCP server. Use when asked to start AgentREPL, launch the Julia REPL MCP server, run its tests, eval Julia code through it, render a plot, or confirm a change works against the running server.
---

AgentREPL.jl is an MCP server that exposes a persistent Julia REPL (eval, sessions, pkg, revise, plots) over JSON-RPC on STDIO. There is no GUI and no network port, so you drive it by being its MCP client: spawn the server, do the `initialize` handshake, call tools. The driver `.claude/skills/run-agentrepl/driver.mjs` does exactly that — use it for everything below.

All paths are relative to the repo root (`/Users/sam/Research/AgentREPL.jl`).

## Prerequisites

Verified on macOS (darwin), Julia 1.12.6, Node v26. Linux is equivalent — there is nothing platform-specific in the launch path.

- **Julia 1.12+** — the `julia` binary on PATH. Installed here via [juliaup](https://github.com/JuliaLang/juliaup).
- **Node 18+** — only for `driver.mjs`. Uses Node stdlib only, no `npm install`.

## Setup

`Manifest.toml` is gitignored, so resolve and precompile deps once after clone (~30s cold):

```bash
julia --project=. -e "using Pkg; Pkg.instantiate(); Pkg.precompile()"
```

Optional — enable Revise.jl hot-reload. Revise is only a test-extra of this package, not a runtime dep, and the worker inherits your global env on its load path. So hot-reload works only if Revise lives in your default environment:

```bash
julia -e 'using Pkg; Pkg.activate(); Pkg.add("Revise")'
```

Without this, `info` reports `Revise.jl: not available` and the server logs one "Worker may have crashed while loading Revise.jl" warning per worker spawn. Eval is unaffected.

## Run (agent path)

Drive the server with `driver.mjs`. It spawns `julia --project=. bin/julia-repl-server`, handles the handshake, and skips the non-JSON chatter the server interleaves on its streams.

Full smoke test — launches, exercises all 8 tools, prints PASS/FAIL, exits non-zero on any failure (~10s warm, after precompile):

```bash
node .claude/skills/run-agentrepl/driver.mjs
```

One-shot eval — spawn, eval, print the formatted result, exit:

```bash
node .claude/skills/run-agentrepl/driver.mjs eval 'using Statistics; mean([1,2,3,4,5])'
```

Call any tool with a JSON args object:

```bash
node .claude/skills/run-agentrepl/driver.mjs call info '{}'
node .claude/skills/run-agentrepl/driver.mjs call session '{"action":"list"}'
```

Interactive — one Julia expression per stdin line, eval'd on a persistent worker (state carries across lines), Ctrl-D to quit:

```bash
printf 'x = collect(1:5)\nsum(x)\nusing UnicodePlots\nlineplot(1:10, sin.(1:10), title="sine")\n' \
  | node .claude/skills/run-agentrepl/driver.mjs repl
```

| command | what it does |
|---|---|
| `driver.mjs` | full smoke test over all 8 tools, PASS/FAIL summary |
| `driver.mjs eval '<code>'` | one eval, prints the formatted result |
| `driver.mjs call <tool> '<json>'` | call any tool (`eval`, `reset`, `info`, `pkg`, `activate`, `log_viewer`, `session`, `revise`) |
| `driver.mjs repl` | interactive eval, one expression per stdin line, state persists |

**Plots are ANSI text, not images.** UnicodePlots renders to a colored ANSI block. The driver prints it to stdout; capture it to a file to inspect:

```bash
node .claude/skills/run-agentrepl/driver.mjs eval 'using UnicodePlots; lineplot(1:10, (1:10).^2)' > /tmp/agentrepl-plot.txt
```

Env overrides for the driver: `JULIA_PROJECT_DIR` (point at a different AgentREPL checkout), `JULIA_BIN` (julia executable path).

## Run (human path)

The server is meant to be registered with an MCP client, not run by hand. With Claude Code, install the plugin (`claude /plugin add samtalki/AgentREPL.jl`) or `claude mcp add`; see README.md. To launch it raw and confirm it speaks MCP, pipe a handshake into the bare entry point (it reads JSON-RPC on stdin, writes responses on stdout, and blocks waiting for a client):

```bash
printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"clientInfo":{"name":"c","version":"1"},"protocolVersion":"2025-06-18"}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | julia --project=. bin/julia-repl-server 2>/dev/null \
  | grep -o '"name":"[a-z_]*"' | sort -u
```

Prints the 8 tool names. `JULIA_REPL_PROJECT=/path` activates a project on the worker; `JULIA_REPL_AUDIT_DIR=/path` enables per-session audit logs.

## Test

```bash
julia --project=. -e "using Pkg; Pkg.test()"           # Aqua + unit suites, 268 tests, ~45s
AGENTREPL_E2E=true julia --project=. -e "using Pkg; Pkg.test()"   # + real server subprocess + transport test, 303 tests
```

During tests you'll see `[worker:<session>:stderr] ...` lines — that is the worker's drained stderr (e.g. project-activation chatter, Revise warnings), routed to the test process's stderr on purpose. The suite still ends with `Testing AgentREPL tests passed`.

## Gotchas

- **Framing is newline-delimited JSON, not LSP `Content-Length`.** One JSON object per line. A client written for the LSP framing will hang. The driver and the raw-launch snippet above both assume NDJSON.
- **The stdout transport is clean JSON; diagnostics go to stderr.** Malt workers keep their stdout/stderr on private pipes (drained to the server's stderr), and the framework's own logs go to stderr too — so the stdout transport carries only JSON-RPC. The driver still skips non-`{` lines defensively, and the bare-launch snippet pipes stderr to `/dev/null`.
- **First eval is slow; the worker spawns lazily.** No worker exists until the first `eval`/`info`/`pkg` call — that call spawns a Malt worker (and loads UnicodePlots/Revise on it). Cold, budget tens of seconds; the driver's per-request timeout is 120s for this reason. Later evals are milliseconds.
- **`reset` kills the worker and drops all state.** It returns fast but the *next* eval pays the worker-spawn cost again. Variables, loaded packages, and `using` imports are gone — that is the point (it enables struct/type redefinition).
- **Revise "not available" is expected on a clean machine.** See Setup. It is graceful degradation, not a failure; eval works regardless.
- **STDIO only, no port.** You cannot `curl` this server. The single local IPC channel is `session attach` (a chmod-600 Unix socket for an interactive human REPL), which needs `tmux` and is out of scope for headless driving.

## Troubleshooting

- **`timeout (120000ms) waiting for tools/call`**: almost always the cold first-eval worker spawn colliding with a precompile. Run the Setup precompile first, then retry.
- **Driver prints `server exited (code=1 ...)`**: the Julia process died on launch. Run `julia --project=. -e "using AgentREPL"` directly to see the real error (usually a missing `Manifest.toml` — run the Setup step).
- **`Package Revise not found` warning floods stderr**: harmless. Silence it for that run by adding Revise to your global env (Setup), or ignore it.
