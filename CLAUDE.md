# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AgentREPL.jl is a Julia package providing a persistent REPL for AI agents via MCP (Model Context Protocol) STDIO transport. It solves Julia's "Time to First X" (TTFX) problem by maintaining a persistent Julia worker subprocess, avoiding the 1-2 second startup penalty for each command.

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

### Worker Subprocess Model

AgentREPL uses a **worker subprocess architecture** (via Distributed.jl):
- The MCP server runs in the main Julia process
- Code evaluation happens in a spawned worker process
- `reset` kills the worker and spawns a fresh one (true hard reset)
- `activate` switches the worker's active project/environment

This design enables true session reset (including type redefinitions) without restarting Claude Code.

### Key Functions

The package lives in `src/AgentREPL.jl` with:

- **`ensure_worker!()`** - Ensures a worker process exists, creating one if needed
- **`kill_worker!()`** / **`reset_worker!()`** - Worker lifecycle management
- **`capture_eval_on_worker(code)`** - Evaluates code on the worker with output capture
- **`format_result(...)`** - Formats results (Result first, then Output, then Code)
- **`activate_project_on_worker!(path)`** - Switches the worker's environment
- **`run_pkg_action_on_worker(action, pkgs)`** - Package management on worker
- **`start_server()`** - Entry point that registers MCP tools and starts the server

### MCP Tools

Five tools registered via ModelContextProtocol.jl:

1. **`eval`** - Evaluates Julia code with persistent state on the worker
2. **`reset`** - **Hard reset**: kills worker, spawns fresh one (enables type redefinition)
3. **`info`** - Returns session metadata (Julia version, project, variables, worker ID)
4. **`pkg`** - Package management (add, rm, status, update, instantiate, resolve, test, develop, free)
5. **`activate`** - Switch active project/environment

### Key Design Decisions

- **Worker subprocess model**: Enables true hard reset with type redefinition
- **Lazy worker spawning**: Worker is created on first tool use, not at server startup (avoids STDIO conflicts with MCP)
- **Expression-based IPC**: Uses `remotecall_fetch(Core.eval, worker_id, Main, expr)` instead of closures to avoid serialization issues
- **STDIO transport only**: No network ports for security
- **Environment persistence**: Activated environment survives reset
- **Result-first formatting**: Shows Result/Error first for better collapsed view UX

## Testing

Tests are in `test/test_eval.jl` covering:
- Code evaluation (arithmetic, variables, functions, multi-line)
- Output capture and error handling
- Result formatting
- Symbol management and protected symbol validation
- Worker subprocess lifecycle (spawn, reset, persistence)
- New pkg actions (test, develop, free)

## Entry Point

`bin/julia-repl-server` is the executable script that loads the module and calls `start_server()`. It accepts `JULIA_REPL_PROJECT` environment variable to activate a specific project on the worker.

## Plugin

The `claude-plugin/` directory contains a Claude Code plugin that:
- Auto-configures the MCP server (no manual `claude mcp add` needed)
- Provides commands: `/julia-reset`, `/julia-info`, `/julia-pkg`, `/julia-activate`
- Includes a skill with best practices for Julia development

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

- **Testing**: Use `pkg(action="test")` to run package tests
- **Development**: Use `pkg(action="develop", packages="./path")` for local package development
- **Environment management**: Use `activate` + `pkg(action="instantiate")` for project-specific environments

See [Modern Julia Workflows](https://modernjuliaworkflows.org/) for best practices.
