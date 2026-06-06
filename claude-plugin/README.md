# Julia Plugin for Claude Code

This plugin provides a persistent Julia REPL for Claude Code with multi-session support and Revise.jl hot-reloading, eliminating the "Time to First X" (TTFX) startup penalty.

## Prerequisites

- Julia 1.12+ installed and available in PATH (verify with `julia --version`)
- AgentREPL.jl package (this repository)

## Installation

Install directly from GitHub:

```bash
claude /plugin add samtalki/AgentREPL.jl
```

Or add the plugin directory locally for development:

```bash
claude --plugin-dir /path/to/AgentREPL.jl/claude-plugin
```

## What's Included

### MCP Server (8 Tools)

The plugin automatically configures the `julia-repl` MCP server which provides:

- `eval` - Evaluate Julia code with persistent state, execution timing, optional timeout, and output truncation
- `reset` - **Hard reset**: kills worker, spawns fresh one (enables type redefinition)
- `info` - Get session information with typed variables, Revise.jl status
- `pkg` - Manage packages (add, rm, status, update, instantiate, resolve, test, develop, free)
- `activate` - Switch project/environment
- `log_viewer` - Open a terminal showing Julia output in real-time
- `session` - **Manage multiple named sessions** (create, switch, list, destroy)
- `revise` - **Hot-reload code changes** via Revise.jl (revise, track, includet, status)

All tools except `log_viewer` and `session` accept an optional `session` parameter. The `session` tool identifies targets via its `name` parameter.

### Skills

**Core skills (auto-triggering):**
- `julia-evaluation` - Behavioral rules for REPL usage (display code before eval, revise vs reset, error recovery)
- `julia-plot` - UnicodePlots setup and display guidance

**User-invoked skills (slash commands):**
- `/julia:julia-reset` - Kill and respawn the Julia worker
- `/julia:julia-info` - Show session information
- `/julia:julia-pkg <action> [packages]` - Package management
- `/julia:julia-activate <path>` - Activate a project/environment
- `/julia:julia-log <mode>` - Control log viewer for real-time output
- `/julia:julia-session <action> [name]` - Manage multiple sessions
- `/julia:julia-revise [action] [path]` - Hot-reload code changes
- `/julia:julia-develop [path]` - Set up a development workflow

### Hooks

- **PreToolUse (eval)** - Ensures Julia code is displayed in a readable format before calling eval
- **PostToolUse (Write/Edit)** - Automatically calls `revise` after editing `.jl` files to hot-reload changes
- **PostToolUse (eval)** - Pastes rich visual output (plots, tables, matrices) as raw text to preserve ANSI colors

## Architecture

AgentREPL uses a **multi-session worker subprocess model**:
- The MCP server runs in the main Julia process
- Each session has its own worker process (via Malt.jl)
- Workers are isolated: separate state, packages, project environments
- Revise.jl is auto-loaded on each worker for hot-reloading
- `reset` kills a session's worker and spawns a fresh one
- This enables true reset including type redefinitions

## Key Design Principle: Maximize Session Lifespan

The plugin is designed to **minimize REPL restarts**:

1. **Revise.jl** auto-loads on every worker — edit `.jl` files and hot-reload without losing state
2. **Multiple sessions** — isolate risky work without affecting your main session
3. **PostToolUse hook** — automatically hot-reloads after editing Julia files
4. **Reset is a last resort** — only needed for struct layout changes (Julia < 1.12) or corrupted state

## Usage

Once installed, simply ask Claude to run Julia code:

> "Calculate the first 20 Fibonacci numbers in Julia"

On first use, Claude will ask about your environment preference:
1. Current directory (activate Project.toml if present)
2. Specific project path
3. Default/global environment

## Multi-Session Workflow

```
/julia:julia-session create analysis    # Create a session for analysis
/julia:julia-session create testing     # Create another for testing
/julia:julia-session switch analysis    # Switch between them
/julia:julia-session list               # See all sessions
```

## Development Workflow

```
/julia:julia-develop .                  # Activate, instantiate, load package, set up Revise

# Edit source files...

/julia:julia-revise                     # Hot-reload changes (or automatic via hook)
/julia:julia-pkg test                   # Run tests
```

## Package Management

| Action | Description | Packages Required |
|--------|-------------|-------------------|
| `add` | Install packages | Yes |
| `rm` | Remove packages | Yes |
| `status` | Show installed packages | No |
| `update` | Update packages | No (optional) |
| `instantiate` | Install from Project.toml | No |
| `resolve` | Update Manifest.toml | No |
| `test` | Run package tests | No (optional) |
| `develop` | Use local package code | Yes (path or name) |
| `free` | Exit development mode | Yes |
