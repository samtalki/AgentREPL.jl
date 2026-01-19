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

### File Structure

The package is split into logical modules:

```
src/
  AgentREPL.jl           # Main module (imports, includes, exports only)
  types.jl               # State structs (WorkerState, LogViewerState, HighlightConfig)
  highlighting.jl        # Julia syntax highlighting (uses JuliaSyntaxHighlighting.jl)
  formatting.jl          # Result formatting, stacktrace truncation
  worker.jl              # Distributed worker lifecycle (ensure_worker!, capture_eval_on_worker)
  packages.jl            # Pkg actions, project activation
  logging.jl             # Log viewer functionality
  tools.jl               # MCP tool definitions
  server.jl              # start_server function
  deprecated/
    tmux.jl              # Deprecated tmux bidirectional REPL (disabled by default)
```

### Syntax Highlighting

Julia code in REPL output is syntax highlighted using [JuliaSyntaxHighlighting.jl](https://julialang.github.io/JuliaSyntaxHighlighting.jl/) (official Julia package).

**Configuration via environment variables:**
- `JULIA_REPL_HIGHLIGHT`: `"true"` (default) or `"false"` - enable/disable highlighting
- `JULIA_REPL_OUTPUT_FORMAT`: `"ansi"` (default), `"markdown"`, or `"plain"` - output format

**Output formats:**
- **ansi**: ANSI escape codes for terminal colors (keywords in red, strings in green, comments in gray)
- **markdown**: Wraps code in ` ```julia ` fences (for future Claude Code markdown rendering support)
- **plain**: No highlighting, returns code as-is

**Example**: Set environment variables in the MCP server configuration:
```bash
JULIA_REPL_HIGHLIGHT=true JULIA_REPL_OUTPUT_FORMAT=ansi julia --project=. bin/julia-repl-server
```

### Key Functions

- **`ensure_worker!()`** - Ensures a worker process exists, creating one if needed (`worker.jl`)
- **`kill_worker!()`** / **`reset_worker!()`** - Worker lifecycle management (`worker.jl`)
- **`capture_eval_on_worker(code)`** - Evaluates code on the worker with output capture (`worker.jl`)
- **`format_result(...)`** - Formats results with syntax highlighting (`formatting.jl`)
- **`highlight_code(code; format)`** - Apply syntax highlighting to Julia code (`highlighting.jl`)
- **`is_highlighting_enabled()`** / **`get_output_format()`** - Configuration getters (`highlighting.jl`)
- **`activate_project_on_worker!(path)`** - Switches the worker's environment (`packages.jl`)
- **`run_pkg_action_on_worker(action, pkgs)`** - Package management on worker (`packages.jl`)
- **`start_server()`** - Entry point that registers MCP tools and starts the server (`server.jl`)

### MCP Tools

Seven tools registered via ModelContextProtocol.jl:

1. **`eval`** - Evaluates Julia code with persistent state on the worker
2. **`reset`** - **Hard reset**: kills worker, spawns fresh one (enables type redefinition)
3. **`info`** - Returns session metadata (Julia version, project, variables, worker ID)
4. **`pkg`** - Package management (add, rm, status, update, instantiate, resolve, test, develop, free)
5. **`activate`** - Switch active project/environment
6. **`log_viewer`** - Control log viewer for visual REPL output
7. **`mode`** - Switch between distributed and tmux modes (tmux is deprecated)

### Key Design Decisions

- **Worker subprocess model**: Enables true hard reset with type redefinition
- **Lazy worker spawning**: Worker is created on first tool use, not at server startup (avoids STDIO conflicts with MCP)
- **Expression-based IPC**: Uses `remotecall_fetch(Core.eval, worker_id, Main, expr)` instead of closures to avoid serialization issues
- **STDIO transport only**: No network ports for security
- **Environment persistence**: Activated environment survives reset
- **Result-first formatting**: Shows Result/Error first for better collapsed view UX

### Tmux Mode Deprecation

The tmux bidirectional REPL mode is **deprecated** and disabled by default. The tmux mode has unfixable architectural issues with marker pollution - the completion detection marker is always visible in the terminal output.

**Recommended alternative**: Use distributed mode (default) with the log viewer for visual output:
- Set `JULIA_REPL_VIEWER=auto` environment variable
- Or manually run: `tail -f ~/.julia/logs/repl.log`

To force-enable tmux mode (not recommended):
- Set `JULIA_REPL_ENABLE_TMUX=true` environment variable

## Testing

Tests are in `test/runtests.jl`, `test/test_eval.jl`, and `test/test_highlighting.jl` covering:
- Code evaluation (arithmetic, variables, functions, multi-line)
- Output capture and error handling
- Result formatting
- Symbol management and protected symbol validation
- Worker subprocess lifecycle (spawn, reset, persistence)
- Pkg actions (test, develop, free)
- Syntax highlighting (ANSI, markdown, plain formats, configuration)

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
