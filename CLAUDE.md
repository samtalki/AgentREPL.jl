# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AgentREPL.jl is a Julia package providing a persistent REPL for AI agents via MCP (Model Context Protocol) STDIO transport. It solves Julia's "Time to First X" (TTFX) problem by maintaining persistent Julia worker subprocesses, avoiding the 1-2 second startup penalty for each command. Supports multiple named sessions and Revise.jl hot-reloading.

## Build and Test Commands

```bash
# Run all tests
julia --project=. -e "using Pkg; Pkg.test()"

# Run a specific test file directly
julia --project=. test/test_eval.jl

# Start the MCP server manually (for debugging)
julia --project=. -e "using AgentREPL; AgentREPL.start_server()"

# Start server with a specific project activated
JULIA_REPL_PROJECT=/path/to/project julia --project=. bin/julia-repl-server
```

## Architecture

### Multi-Session Worker Subprocess Model

AgentREPL uses a **multi-session worker subprocess architecture** (via Distributed.jl):
- The MCP server runs in the main Julia process
- Each named session has its own worker process for code evaluation
- Sessions are isolated: separate variables, packages, and project environments
- `reset` kills a session's worker and spawns a fresh one (true hard reset)
- `activate` switches a session's active project/environment
- Revise.jl is auto-loaded on workers for hot-reloading support

### File Structure

```
src/
  AgentREPL.jl           # Main module (imports, includes, exports only)
  types.jl               # State structs (SessionState, SessionRegistry, WorkerState, LogViewerState, HighlightConfig)
  highlighting.jl        # Julia syntax highlighting (uses JuliaSyntaxHighlighting.jl)
  formatting.jl          # Result formatting, stacktrace truncation
  sessions.jl            # Multi-session lifecycle (create, switch, list, destroy)
  worker.jl              # Distributed worker lifecycle (ensure_worker!, capture_eval_on_worker)
  revise.jl              # Revise.jl integration (revise, track, includet on workers)
  packages.jl            # Pkg actions, project activation
  logging.jl             # Log viewer functionality
  tools.jl               # MCP tool definitions (8 tools)
  server.jl              # start_server function
  deprecated/
    tmux.jl              # Removed (was deprecated tmux REPL)
```

### Syntax Highlighting

Julia code in REPL output is syntax highlighted using [JuliaSyntaxHighlighting.jl](https://julialang.github.io/JuliaSyntaxHighlighting.jl/) (official Julia package).

**Configuration via environment variables:**
- `JULIA_REPL_HIGHLIGHT`: `"true"` (default) or `"false"` - enable/disable highlighting
- `JULIA_REPL_OUTPUT_FORMAT`: `"ansi"` (default), `"markdown"`, or `"plain"` - output format

### Key Functions

**Session Management (`sessions.jl`):**
- **`get_current_session!()`** - Get current session, auto-creates "default" if none
- **`create_session!(name)`** - Create a new named session
- **`switch_session!(name)`** - Switch to a different session
- **`destroy_session!(name)`** - Kill session and its worker
- **`list_sessions()`** - List all sessions with status
- **`resolve_session(name)`** - Resolve optional session name to SessionState

**Worker Lifecycle (`worker.jl`):**
- **`ensure_worker!(session)`** - Ensure worker exists for a session, creating one if needed
- **`kill_worker!(session)`** / **`reset_worker!(session)`** - Worker lifecycle management
- **`capture_eval_on_worker(code; timeout, session_name)`** - Evaluate code with output capture
- **`get_worker_info(session)`** - Returns session metadata

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

1. **`eval`** - Evaluates Julia code with persistent state on the worker
2. **`reset`** - **Hard reset**: kills worker, spawns fresh one (enables type redefinition)
3. **`info`** - Returns session metadata (Julia version, project, variables, Revise status)
4. **`pkg`** - Package management (add, rm, status, update, instantiate, resolve, test, develop, free)
5. **`activate`** - Switch active project/environment
6. **`log_viewer`** - Control log viewer for visual REPL output
7. **`session`** - Manage multiple named sessions (create, switch, list, destroy)
8. **`revise`** - Hot-reload code changes via Revise.jl (revise, track, includet, status)

All tools except `log_viewer` accept an optional `session` parameter.

### Key Design Decisions

- **Multi-session model**: Each session has its own Distributed.jl worker with isolated state
- **Backward compatibility**: Global `WORKER` state kept synchronized with current session
- **Revise.jl auto-loading**: Workers attempt `using Revise` on startup (graceful degradation)
- **Lazy worker spawning**: Worker created on first tool use, not at server startup
- **Expression-based IPC**: Uses `remotecall_fetch(Core.eval, worker_id, Main, expr)` to avoid serialization issues
- **STDIO transport only**: No network ports for security
- **Environment persistence**: Activated environment survives reset
- **Result-first formatting**: Shows Result/Error first for better collapsed view UX

## Testing

Tests are in `test/runtests.jl`, `test/test_eval.jl`, `test/test_sessions.jl`, and `test/test_highlighting.jl` covering:
- Code evaluation (arithmetic, variables, functions, multi-line)
- Output capture and error handling
- Result formatting and truncation
- Worker subprocess lifecycle (spawn, reset, persistence)
- Multi-session management (create, switch, isolate, destroy)
- Session-targeted evaluation
- Pkg actions (test, develop, free)
- Syntax highlighting (ANSI, markdown, plain formats)

## Entry Point

`bin/julia-repl-server` is the executable script that loads the module and calls `start_server()`. It accepts `JULIA_REPL_PROJECT` environment variable to activate a specific project on the worker.

## Plugin

The `claude-plugin/` directory contains a Claude Code plugin that:
- Auto-configures the MCP server (no manual `claude mcp add` needed)
- Provides skills: `/julia-reset`, `/julia-info`, `/julia-pkg`, `/julia-activate`, `/julia-log`, `/julia-session`, `/julia-revise`, `/julia-develop`
- Includes auto-triggering skills for Julia evaluation best practices and language expertise
- Has hooks: PreToolUse (code display validation), PostToolUse (auto-Revise on .jl file edits)

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
