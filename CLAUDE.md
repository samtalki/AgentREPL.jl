# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AgentREPL.jl is a Julia package providing a persistent REPL for AI agents via MCP (Model Context Protocol) STDIO transport. It solves Julia's "Time to First X" (TTFX) problem by maintaining persistent Julia worker subprocesses, avoiding the 1-2 second startup penalty for each command. Supports multiple named sessions and Revise.jl hot-reloading.

## Build and Test Commands

```bash
# Run all tests (Aqua quality + unit suites; fast, no subprocess spawning)
julia --project=. -e "using Pkg; Pkg.test()"

# Include the MCP protocol integration tests (spawns a server subprocess, ~60s)
AGENTREPL_E2E=true julia --project=. -e "using Pkg; Pkg.test()"

# Run a specific test file directly
julia --project=. test/test_eval.jl

# Start the MCP server manually (for debugging)
julia --project=. -e "using AgentREPL; AgentREPL.start_server()"

# Start server with a specific project activated
JULIA_REPL_PROJECT=/path/to/project julia --project=. bin/julia-repl-server
```

## Architecture

### Multi-Session Worker Subprocess Model

AgentREPL uses a **multi-session worker subprocess architecture** (via [Malt.jl](https://github.com/JuliaPluto/Malt.jl)):
- The MCP server runs in the main Julia process
- Each named session has its own `Malt.Worker` process for code evaluation
- Sessions are isolated: separate variables, packages, and project environments
- `reset` kills a session's worker and spawns a fresh one (true hard reset)
- `activate` switches a session's active project/environment
- Revise.jl is auto-loaded on workers for hot-reloading support

**Why Malt, not Distributed.jl**: Malt spawns workers with `monitor_stdout=false`/`monitor_stderr=false`, so worker output goes to private pipes (drained to the server's stderr by `_start_output_drain!`) and can never reach the main process's stdout — which is the MCP JSON-RPC transport. Malt also has no global cluster state (each `Worker` is an independent object) and provides graceful `stop` (exit → SIGTERM → SIGKILL), `isrunning`, and `TerminatedWorkerException`, replacing hand-rolled lifecycle code. IPC is `Malt.remote_eval_fetch(Main, w, expr)` via the `_remote_eval_fetch` helper.

### File Structure

Files are `include`d in dependency order from `AgentREPL.jl`. `repl_client.jl` is the one exception: it is a standalone script run as a subprocess, not part of the module.

```
src/
  AgentREPL.jl           # Main module (imports, includes, exports only)
  types.jl               # State structs (SessionState, SessionRegistry, LogViewerState, HighlightConfig) + audit/registry globals
  highlighting.jl        # Julia syntax highlighting (uses JuliaSyntaxHighlighting.jl)
  formatting.jl          # Result formatting, stacktrace truncation
  sessions.jl            # Multi-session lifecycle (create, switch, list, destroy)
  worker.jl              # Malt worker lifecycle (ensure_worker!, capture_eval_on_worker, output drain, workspace restore)
  revise.jl              # Revise.jl integration (revise, track, includet on workers)
  packages.jl            # Pkg actions, project activation
  logging.jl             # Log viewer + persistent audit logging
  attach.jl              # Interactive shared REPL: Unix socket server on worker + tmux client launcher
  repl_client.jl         # Standalone REPL client (run via tmux subprocess, NOT included in module)
  tools.jl               # MCP tool definitions (8 tools)
  resources.jl           # MCP resources (session variables, info, project, log, sessions)
  prompts.jl             # MCP prompts (julia-dev-setup, julia-benchmark, julia-debug-error)
  server.jl              # start_server function (registers tools + resources + prompts, declares capabilities)
```

### Syntax Highlighting

Julia code in REPL output is syntax highlighted using [JuliaSyntaxHighlighting.jl](https://julialang.github.io/JuliaSyntaxHighlighting.jl/) (official Julia package).

**Configuration via environment variables:**
- `JULIA_REPL_HIGHLIGHT`: `"true"` (default) or `"false"` - enable/disable highlighting
- `JULIA_REPL_OUTPUT_FORMAT`: `"ansi"` (default), `"markdown"`, or `"plain"` - output format

### Plotting

UnicodePlots.jl is a dependency loaded on workers (not in the main module). `capture_eval_on_worker` passes the color preference into the worker so `repr` renders color-aware types (UnicodePlots output) with ANSI. The `julia-plot` skill tells the user to expand the tool result (Ctrl+O) for color rather than pasting ANSI art into chat.

### Audit Logging

Set `JULIA_REPL_AUDIT_DIR` to enable persistent per-session audit logs that survive server restarts. `server.jl` creates the directory and sets `_AUDIT_DIR`; `logging.jl` (`_get_audit_io`) appends each eval interaction to `{dir}/{session}_{date}.log`. Disabled by default.

### Key Functions

**Session Management (`sessions.jl`):**
- **`get_current_session!()`** - Get current session, auto-creates "default" if none
- **`create_session!(name)`** - Create a new named session
- **`switch_session!(name)`** - Switch to a different session
- **`destroy_session!(name)`** - Kill session and its worker
- **`list_sessions()`** - List all sessions with status (the `worker_pid` field carries the OS pid)
- **`resolve_session(name)`** - Resolve optional session name to SessionState

**Worker Lifecycle (`worker.jl`):**
- **`ensure_worker!(session)`** - Ensure a worker exists for a session, creating one if needed; returns the `Malt.Worker`
- **`worker_live(session)`** / **`worker_pid(session)`** - Liveness predicate and OS pid (a non-`nothing` worker may still be dead)
- **`kill_worker!(session)`** / **`reset_worker!(session)`** - Worker lifecycle management
- **`capture_eval_on_worker(code; timeout, session_name, isolated)`** - Evaluate code with output capture; `isolated=true` runs in a fresh anonymous module so nothing persists
- **`get_worker_info(session)`** - Returns session metadata
- **`_remote_eval_fetch(w, expr)`** - The one IPC spelling (`Malt.remote_eval_fetch(Main, w, expr)`)

**Interactive REPL (`attach.jl`):**
- **`_start_repl_socket_server!(session)`** - Start a chmod-600 Unix domain socket server on the worker that evals incoming base64 code in `Main` (shares state with MCP eval)
- **`_open_attach_tmux(session)`** - Launch `repl_client.jl` in tmux and open a terminal connected to the socket

**Revise Integration (`revise.jl`):**
- **`revise_on_worker!(session)`** - Call Revise.revise() on worker
- **`track_file_on_worker!(session, filepath)`** - Track a file with Revise
- **`includet_on_worker!(session, filepath)`** - Hot-reloadable include
- **`is_revise_available(session)`** - Check if Revise is loaded
- **`get_revise_status(session)`** - Get tracking status

**Formatting (`formatting.jl`):**
- **`truncate_output(text, max_chars)`** - Truncate text keeping head (60%) and tail (40%)
- **`format_elapsed(elapsed)`** - Format elapsed time as human-readable string
- **`format_result(...)`** - Formats results with syntax highlighting

**Packages (`packages.jl`):**
- **`activate_project_on_worker!(path; session_name)`** - Switches environment
- **`run_pkg_action_on_worker(action, pkgs; session_name)`** - Package management

### MCP Tools

Eight tools registered via ModelContextProtocol.jl:

1. **`eval`** - Evaluates Julia code with persistent state on the worker. Optional params: `timeout` (kills the worker if exceeded), `max_output` (default 50000 chars), `max_stackframes` (default 5), `isolated` (eval in a throwaway module, no persistence), `ephemeral` (spin up a temporary session + worker, eval, then destroy it for full process isolation)
2. **`reset`** - **Hard reset**: kills worker, spawns fresh one (enables type redefinition)
3. **`info`** - Returns session metadata (Julia version, project, variables, Revise status, worker pid)
4. **`pkg`** - Package management (add, rm, status, update, instantiate, resolve, test, develop, free)
5. **`activate`** - Switch active project/environment
6. **`log_viewer`** - Control log viewer for visual REPL output
7. **`session`** - Manage multiple named sessions (create, switch, list, destroy, attach). `attach` opens an interactive human-facing REPL sharing the session's worker state
8. **`revise`** - Hot-reload code changes via Revise.jl (revise, track, includet, status)

All tools except `log_viewer` and `session` accept an optional `session` parameter. The `session` tool identifies targets via its `name` parameter instead. Each tool carries a human-friendly `title`.

### MCP Resources

Five read-only resources (`resources.jl`) expose session state so a client can pull it into context (Claude Code surfaces them as @-mentions) without spending an eval/info tool call. Reads have **no side effects** — they never spawn a worker — and `_resource_safe` tags each result `ok=true` or `(ok=false, error=...)`:

- `agentrepl://sessions` - all sessions with worker pid, project, Revise status, age
- `agentrepl://session/variables` - user variables (name, type, size) in the current session
- `agentrepl://session/info` - Julia version, project, module count, Revise status, worker pid, setup notes
- `agentrepl://session/project` - active `Project.toml` contents and whether a `Manifest.toml` is present
- `agentrepl://session/log` - recent out-of-band worker output (`recent_output` ring: spawn-time precompile, async prints) plus audit-log entries when `JULIA_REPL_AUDIT_DIR` is set

### MCP Prompts

Three prompts (`prompts.jl`) expose reusable Julia workflows as slash commands (work without the plugin). Static `MCPPrompt` templates with `{arg}`/`{?arg?…}` substitution handled by the framework: `julia-dev-setup` (arg `path`), `julia-benchmark` (arg `code`), `julia-debug-error` (args `code`, `error?`). Registered in `start_server` with `PromptCapability`.

### Key Design Decisions

- **Multi-session model**: Each session has its own `Malt.Worker` with isolated state
- **Transport isolation**: Workers run with `monitor_stdout/stderr=false`; `_start_output_drain!` drains their pipes to the server's stderr so worker output never corrupts the stdout JSON-RPC stream. `get_worker_info` snapshots a baseline of `Main` symbols at spawn so Malt's own worker-loop globals don't show up as user variables
- **Revise.jl auto-loading**: Workers attempt `using Revise` on startup; a load failure is recorded in `session.worker_notes` and surfaced in `info` / the next eval rather than only logged (graceful degradation)
- **Lazy worker spawning**: Worker created on first tool use, not at server startup
- **Expression-based IPC**: `_remote_eval_fetch(w, expr)` (= `Malt.remote_eval_fetch(Main, w, expr)`) to avoid closure serialization issues
- **Capabilities**: `start_server` declares only Tools + Resources (no prompts, no resource subscriptions), instead of the framework default that over-advertises
- **STDIO transport only**: No network ports for security. The `session attach` socket is the one local IPC channel, a Unix domain socket chmod 600 (owner only)
- **Environment persistence**: Activated environment survives reset. `workspace_path` (set by `activate`) is the working directory restored on every worker spawn/reset; `eval`-time `cd()` calls do not change it
- **Three isolation levels for eval**: shared `Main` (default), `isolated` (throwaway module, same worker), `ephemeral` (throwaway session + worker)
- **Output-then-result formatting**: Shows stdout first, then result/error, then timing — optimized for collapsed view UX

**Framework limitations (would need a ModelContextProtocol.jl PR):** the released `MCPTool` has no `annotations` field and `handle_list_tools` does not serialize one, so tool hints (`readOnlyHint`/`destructiveHint`) are not available — only `title` is. There is no tool `output_schema`/`structuredContent` support, so tools return text and richer structured state is exposed via **resources** instead. (Both are implemented on a fork and wired on a separate branch, pending an upstream release.)

## Testing

`test/runtests.jl` runs an Aqua.jl code quality pass (ambiguities off; `UnicodePlots` ignored in the stale-dep check since it is only used on workers) then includes the unit suites. `test/test_mcp_protocol.jl` is gated behind `AGENTREPL_E2E=true` because it spawns a real server subprocess.

Unit suites:
- `test_eval.jl` - evaluation, output capture, error handling, formatting/truncation, worker lifecycle (spawn, reset, timeout kill, crash recovery), `worker_notes` surfacing
- `test_sessions.jl` - multi-session management (create, switch, isolate, destroy), session-targeted eval, Pkg actions (test, develop, free)
- `test_competitive_features.jl` - isolated eval, ephemeral sessions, audit logging, workspace sync, attach socket lifecycle
- `test_revise.jl` - Revise.jl integration (status, availability)
- `test_highlighting.jl` - syntax highlighting (ANSI, markdown, plain formats)
- `test_resources.jl` - the five MCP resources, the ok/error discriminant, non-spawning reads, audit-log branches
- `test_mcp_protocol.jl` - end-to-end MCP protocol over the server subprocess, incl. transport-stream cleanliness (E2E-gated)

Shell scripts `test/test_e2e_agent.sh` and `test/test_plugin_validation.sh` exercise the server and plugin manifest outside the Julia test runner.

## Entry Point

`bin/julia-repl-server` is the executable script that loads the module and calls `start_server()`. It accepts `JULIA_REPL_PROJECT` environment variable to activate a specific project on the worker.

## Plugin

The `claude-plugin/` directory contains the plugin itself; `.claude-plugin/marketplace.json` is the marketplace manifest that points at it. The plugin:
- Auto-configures the MCP server (no manual `claude mcp add` needed)
- Provides user-invoked skills: `/julia-reset`, `/julia-info`, `/julia-pkg`, `/julia-activate`, `/julia-log`, `/julia-session`, `/julia-revise`, `/julia-develop`
- Includes auto-triggering skills: `julia-evaluation` (REPL best practices, in `skills/julia/`) and `julia-plot` (plotting guidance)
- Has one hook (`claude-plugin/hooks/hooks.json` runs `hooks/revise-nudge.sh`): a non-blocking PostToolUse hook on Write/Edit that injects an `additionalContext` reminder to call `revise` after a `.jl` edit. The guidance to display code before `eval` and to expand plot results for color lives in the `julia-evaluation`/`julia-plot` skills, not hooks.

Install with:
```bash
claude /plugin add samtalki/AgentREPL.jl
```

Or for local development:
```bash
claude --plugin-dir ./claude-plugin
```

## Using the MCP Tools

**Important**: When using `eval`, always display the code in a readable format in your message BEFORE calling the tool. The MCP permission prompt shows code as an escaped string which is unreadable. By showing the code first, users can verify what will be executed before approving.

Example:
```
Running this Julia code:
```julia
x = 1 + 1
println("Hello!")
```

[then call eval]
```

## Modern Julia Workflows

This package supports modern Julia development workflows:

- **Hot-reloading**: Use `revise(action="revise")` after editing .jl files to reload changes without restart
- **Multi-session**: Use `session(action="create", name="...")` for parallel isolated workspaces
- **Testing**: Use `pkg(action="test")` to run package tests (call `revise` first for latest changes)
- **Development**: Use `pkg(action="develop", packages="./path")` + Revise for local package development
- **Environment management**: Use `activate` + `pkg(action="instantiate")` for project-specific environments

See [Modern Julia Workflows](https://modernjuliaworkflows.org/) for best practices.
