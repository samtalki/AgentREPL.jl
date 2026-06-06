# AgentREPL.jl

Persistent Julia REPL for AI agents via MCP (Model Context Protocol). Supports multiple isolated sessions and Revise.jl hot-reloading.

**The Problem:** Julia's "Time to First X" (TTFX) problem severely impacts AI agent workflows. Each `julia -e "..."` call incurs 1-2s startup + package loading + JIT compilation. AI agents like Claude Code spawn fresh Julia processes per command, wasting minutes of compute time.

**The Solution:** AgentREPL provides a persistent Julia session via MCP STDIO transport. The Julia process stays alive, so you only pay the TTFX cost once.

## Why AgentREPL?

AgentREPL is the simplest way to give Claude Code a persistent Julia session. Three things set it apart:

1. **Zero-friction setup.** STDIO transport means Claude Code spawns and manages the Julia process automatically. No server to start, no port to configure, no process to monitor. Install the plugin and start coding.

2. **Workflow-native Revise.jl.** Every worker auto-loads Revise.jl. The plugin's PostToolUse hook automatically calls `revise` after you edit `.jl` files. You never manually reload code.

3. **True process isolation.** Each session is a separate Distributed.jl worker. You can redefine structs, kill crashed sessions, and run parallel workloads without cross-contamination. `reset` does what it says -- complete state erasure including type definitions.

AgentREPL is not a Julia IDE replacement. It has 8 tools, not 35. It does not have debugging, semantic search, or a dashboard. If you need those, see the [comparison section](#choosing-a-julia-mcp-server) below. AgentREPL's approach is that `eval` plus Julia's existing introspection capabilities (which you can call directly via `eval`) covers most agent workflows with minimal complexity.

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/samtalki/AgentREPL.jl")
```

Or for development:

```julia
Pkg.dev("https://github.com/samtalki/AgentREPL.jl")
```

## Quick Start

### Option A: Use the Plugin (Recommended)

The easiest way to use AgentREPL is via the included Claude Code plugin:

```bash
claude /plugin add samtalki/AgentREPL.jl
```

This provides:
- Auto-configured MCP server (no manual setup)
- 8 skills: `/julia-reset`, `/julia-info`, `/julia-pkg`, `/julia-activate`, `/julia-log`, `/julia-session`, `/julia-revise`, `/julia-develop`
- Auto-triggering skills for Julia evaluation best practices and terminal plotting
- Hooks: code display validation before `eval`, automatic `revise` after `.jl` file edits

### Option B: Manual MCP Configuration

```bash
claude mcp add julia-repl -- julia --project=/path/to/AgentREPL.jl /path/to/AgentREPL.jl/bin/julia-repl-server
```

### Using AgentREPL

Start a new Claude Code session. The Julia MCP server will auto-start when Claude needs it.

Ask Claude to run Julia code:
> "Calculate the first 10 Fibonacci numbers in Julia"

Claude will use the `eval` tool and display REPL-style output:

```
julia> [fibonacci(i) for i in 1:10]

[1, 1, 2, 3, 5, 8, 13, 21, 34, 55]
```

The first call may take a few seconds for JIT compilation; subsequent calls are instant.

## Architecture

AgentREPL uses a **multi-session worker subprocess model** via Distributed.jl:

```
┌─────────────────────────────────────────────────────────┐
│ Claude Code                                             │
│   ↕ STDIO (MCP)                                        │
│ ┌─────────────────────────────────────────────────────┐ │
│ │ AgentREPL MCP Server (Main Process)                 │ │
│ │   ↕ Distributed.jl                                  │ │
│ │ ┌──────────────────┐  ┌──────────────────┐          │ │
│ │ │ Session "default" │  │ Session "testing" │  ...    │ │
│ │ │ (Worker 2)        │  │ (Worker 3)        │         │ │
│ │ └──────────────────┘  └──────────────────┘          │ │
│ └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

**Why a worker subprocess?**
- `reset` can kill and respawn the worker for a **true hard reset**
- Type/struct redefinitions work (impossible with in-process reset)
- Each session has isolated variables, packages, and project environment
- The activated environment persists across resets
- Workers are spawned lazily on first use to avoid STDIO conflicts

## Tools Provided

### `eval`

Evaluate Julia code in a persistent session. Output is formatted in familiar REPL style:

```
julia> x = 1 + 1

2
```

```
julia> x + 10

12
```

Variables persist! Multi-line code works too:

```
julia> function fib(n)
           n <= 1 && return n
           fib(n-1) + fib(n-2)
       end
       [fib(i) for i in 1:10]

[1, 1, 2, 3, 5, 8, 13, 21, 34, 55]
```

Printed output appears before the result:

```
julia> println("Computing..."); 42

Computing...
42
```

Errors are caught with truncated stacktraces:

```
julia> undefined_var

UndefVarError: `undefined_var` not defined
Stacktrace:
 [1] top-level scope
  ... (truncated)
```

Features:
- Variables and functions persist across calls
- Packages loaded once stay loaded
- Both return values and printed output are captured
- Errors are caught and reported with backtraces

### `reset`

**Hard reset**: Kills the worker process and spawns a fresh one.

```
Session reset complete.
- Old worker (ID: 2) terminated
- New worker (ID: 3) spawned
- All variables, functions, and types cleared
- Packages will need to be reloaded with `using`
```

This enables:
- Clearing all variables
- Unloading all packages
- **Redefining types/structs** (impossible with soft resets)
- Starting with a completely fresh Julia state

The activated environment persists across resets.

### `info`

Get session information including worker process ID.

```
Julia Version: 1.12.2
Active Project: /home/user/MyProject
User Variables: x, fib, data
Loaded Modules: 42
Worker ID: 3
Session: default
Revise.jl: loaded
```

### `activate`

Switch the active Julia project/environment.

```
activate(path=".")
# Activated project: /home/user/MyProject
# Use `pkg(action="instantiate")` to install dependencies if needed.

activate(path="/path/to/OtherProject")
# Activated project: /path/to/OtherProject

activate(path="@v1.10")
# Activated shared environment: @v1.10
```

After activation, install dependencies with:
```
pkg(action="instantiate")
```

### `pkg`

Manage Julia packages in the current environment.

```
pkg(action="status")
# Package Status:
# Project MyProject v0.1.0
# Status `~/MyProject/Project.toml`
#   [682c06a0] JSON3 v1.14.0
#   [a93c6f00] DataFrames v1.6.1

pkg(action="add", packages="CSV, HTTP")
# Package add complete.

pkg(action="test")
# Test Summary: | Pass  Total
# MyProject     |   42     42

pkg(action="develop", packages="./MyLocalPackage")
# Development mode: MyLocalPackage -> ~/MyLocalPackage

pkg(action="free", packages="MyLocalPackage")
# Freed MyLocalPackage from development mode
```

**Actions:**
| Action | Description | Packages Required |
|--------|-------------|-------------------|
| `add` | Install packages | Yes |
| `rm` | Remove packages | Yes |
| `status` | Show installed packages | No |
| `update` | Update packages (all if not specified) | No |
| `instantiate` | Install from Project.toml/Manifest.toml | No |
| `resolve` | Resolve dependency graph | No |
| `test` | Run tests (current project if not specified) | No |
| `develop` | Use local code instead of registry | Yes |
| `free` | Return to registry version | Yes |

The `packages` parameter accepts space or comma-separated names.

### `log_viewer`

Open a terminal showing Julia output in real-time.

```
log_viewer(mode="auto")
# Log viewer enabled.
# Log file: ~/.julia/logs/repl.log
# A terminal window should have opened.

log_viewer(mode="tmux")
# tmux session 'julia-repl' created. Attach with: tmux attach -t julia-repl

log_viewer(mode="file")
# Log file: ~/.julia/logs/repl.log
# Run manually: tail -f ~/.julia/logs/repl.log

log_viewer(mode="off")
# Log viewer disabled.
```

Useful for seeing printed output as it happens, especially for long-running computations.

### `session`

Manage multiple named Julia REPL sessions. Each session has its own worker process with isolated state.

```
session(action="create", name="analysis")
# Session 'analysis' created and set as current.
# Worker will spawn on first eval.

session(action="list")
# Sessions:
#  * default — worker 2, /home/user/MyProject, Revise (5.2min)
#    analysis — not spawned, default env, no Revise (0.1min)

session(action="switch", name="analysis")
# Switched to session 'analysis'.

session(action="destroy", name="analysis")
# Session 'analysis' destroyed.
```

**Actions:**
| Action | Description | Name Required |
|--------|-------------|---------------|
| `create` | Create a new named session | Yes |
| `switch` | Switch the active session | Yes |
| `list` | Show all sessions with status | No |
| `destroy` | Kill a session's worker and remove it | Yes |

### `revise`

Hot-reload Julia code changes using Revise.jl -- no session restart needed.

```
revise(action="revise")
# Revise completed — all tracked changes reloaded.

revise(action="track", path="src/myfile.jl")
# Now tracking src/myfile.jl — changes will auto-reload on next revise().

revise(action="includet", path="scripts/analysis.jl")
# Included scripts/analysis.jl with Revise tracking.

revise(action="status")
# Revise.jl Status (session: default):
# Watched packages: MyPackage
# Tracked files: 3 files
#   - src/core.jl
#   - src/utils.jl
#   - scripts/analysis.jl
```

**Actions:**
| Action | Description | Path Required |
|--------|-------------|---------------|
| `revise` | Trigger Revise.revise() to pick up all file changes | No |
| `track` | Start tracking a file (changes auto-detected) | Yes |
| `includet` | Include a file with Revise tracking | Yes |
| `status` | Show what Revise is currently tracking | No |

Use `revise` after editing `.jl` files. Use `reset` only for struct layout changes (Julia < 1.12) or corrupted state.

All tools except `log_viewer` and `session` accept an optional `session` parameter to target a specific session.

## Configuration

### Environment/Project Management

There are three ways to set the Julia environment:

**1. At runtime (recommended)**: Use `activate` to switch environments dynamically:
```
activate(path="/path/to/your/project")
pkg(action="instantiate")
```

**2. Via environment variable**: Set `JULIA_REPL_PROJECT` before starting:
```bash
JULIA_REPL_PROJECT=/path/to/your/project claude mcp add julia-repl -- julia --project=/path/to/AgentREPL.jl -e "using AgentREPL; AgentREPL.start_server()"
```

**3. In code**: Pass directly to the server:
```julia
AgentREPL.start_server(project_dir="/path/to/your/project")
```

The activated environment persists across `reset` calls.

## Choosing a Julia MCP Server

| | AgentREPL | Kaimon.jl | MCPRepl.jl |
|---|---|---|---|
| Transport | STDIO | HTTP (+ZMQ) | HTTP |
| Network port | None | 2828 | 3000 |
| Auto-start from Claude Code | Yes | No | No |
| Dependencies | 5 (3 stdlib) | 30+ | Few |
| Session isolation | Process-level (Distributed.jl) | Via Gate | Shared REPL |
| Revise.jl integration | Auto-load + auto-revise hook | Manual | No |
| True hard reset (type redef) | Yes | N/A | No |
| Debugging (breakpoints, stepping) | No | Yes (VS Code) | No |
| Semantic code search | No | Yes (Qdrant) | No |
| Introspection tools | No (use `eval`) | Yes (dedicated) | No |
| TUI dashboard | No | Yes | No |
| Custom tool registration | No | Yes (GateTool) | No |
| Plugin ecosystem (skills/hooks) | Yes | No | No |
| Registry-eligible | Yes | No | No |

**Choose AgentREPL if** you want a zero-config Julia REPL that auto-starts when Claude Code needs it. No port, automatic Revise.jl hot-reloading, multi-session isolation. You value simplicity and security over feature breadth.

**Choose [Kaimon.jl](https://github.com/kahliburke/Kaimon.jl) if** you want a comprehensive Julia development environment with 35+ tools: debugging, semantic code search, macro expansion, code IR inspection, and a terminal dashboard. You're comfortable managing HTTP server startup and a larger dependency tree.

**Choose [MCPRepl.jl](https://github.com/hexaeder/MCPRepl.jl) if** you want a shared REPL where you and the AI agent see each other's commands in real-time.

AgentREPL deliberately does not include debugging, semantic search, introspection tools, a TUI, or custom tool registration. If you need those, Kaimon.jl provides them. AgentREPL's trade-off is that `eval` plus Julia's built-in introspection (e.g., `@code_typed`, `methodswith`, `supertypes` -- all callable via `eval`) covers most agent workflows with fewer moving parts.

### Related Tools

- [Auton.jl](https://github.com/AntonOresten/Auton.jl) -- LLM-augmented REPL modes for human-in-the-loop Julia development
- [ClaudeCodeSDK.jl](https://github.com/AtelierArith/ClaudeCodeSDK.jl) -- Call Claude Code from Julia (opposite direction)
- [ModelContextProtocol.jl](https://github.com/JuliaSMLM/ModelContextProtocol.jl) -- The MCP framework AgentREPL is built on
- [ClaudeCodeJuliaLSP](https://github.com/Piebald-AI/claude-code-lsps) -- Code intelligence (diagnostics, go-to-definition) for Claude Code
- [juliadoc-mcp](https://github.com/jonathanfischer97/juliadoc-mcp) -- Julia documentation lookup via MCP
- [REPLicant.jl](https://github.com/MichaelHatherly/REPLicant.jl) -- TCP-based Julia REPL with custom protocol

## Claude Code Plugin

The `claude-plugin/` directory contains a ready-to-use Claude Code plugin.

### Auto-configured MCP Server
No need to manually run `claude mcp add`. The plugin configures the Julia MCP server automatically.

### Skills

**User-invoked:**
| Skill | Description |
|-------|-------------|
| `/julia:julia-reset` | Kill and respawn the Julia worker (hard reset) |
| `/julia:julia-info` | Show session information |
| `/julia:julia-pkg <action> [packages]` | Package management |
| `/julia:julia-activate <path>` | Activate a project/environment |
| `/julia:julia-log <mode>` | Control log viewer |
| `/julia:julia-session <action> [name]` | Manage multiple sessions |
| `/julia:julia-revise [action] [path]` | Hot-reload code changes |
| `/julia:julia-develop [path]` | Set up development workflow |

**Auto-triggering:** `julia-evaluation` (best practices for REPL usage) and `julia-plot` (terminal-native plotting with UnicodePlots.jl).

### Hooks

- **PreToolUse (eval)**: Validates that Julia code is displayed in a readable format before calling eval
- **PostToolUse (Write/Edit)**: Automatically calls `revise` after editing `.jl` files to hot-reload changes

### Installation
```bash
claude /plugin add samtalki/AgentREPL.jl
```

Or for local development:
```bash
claude --plugin-dir /path/to/AgentREPL.jl/claude-plugin
```

See [claude-plugin/README.md](claude-plugin/README.md) for details.

## Security

See [SECURITY.md](SECURITY.md) for detailed security considerations.

**TL;DR**:
- STDIO transport = no network attack surface
- Code runs with user permissions
- Process terminates when Claude session ends
- No protection against malicious code (AI decides what to run)

## Development

### Running Tests

```bash
julia --project=. -e "using Pkg; Pkg.test()"
```

### Local Testing

```julia
using AgentREPL
AgentREPL.start_server()  # Blocks, waiting for MCP messages on stdin
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed contribution guidelines.

## API Reference

### Exported Functions

#### `start_server(; project_dir=nothing)`

Start the AgentREPL MCP server using STDIO transport.

**Arguments:**
- `project_dir::Union{String,Nothing}`: Optional path to a Julia project to activate on the worker

**Example:**
```julia
using AgentREPL
AgentREPL.start_server(project_dir="/path/to/myproject")
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `JULIA_REPL_PROJECT` | Path to Julia project to activate on startup | None |
| `JULIA_REPL_VIEWER` | Log viewer mode: `auto`, `tmux`, `file`, `none` | `none` |
| `JULIA_REPL_LOG` | Path to log file | `~/.julia/logs/repl.log` |
| `JULIA_REPL_HIGHLIGHT` | Enable/disable syntax highlighting | `true` |
| `JULIA_REPL_OUTPUT_FORMAT` | Output format: `ansi`, `markdown`, `plain` | `ansi` |

### Internal Architecture

For developers extending AgentREPL:

**File Structure:**
```
src/
  AgentREPL.jl           # Main module (imports, includes, exports)
  types.jl               # State structs (SessionState, SessionRegistry, LogViewerState, HighlightConfig)
  highlighting.jl        # Julia syntax highlighting (JuliaSyntaxHighlighting.jl)
  formatting.jl          # Result formatting, stacktrace truncation
  sessions.jl            # Multi-session lifecycle (create, switch, list, destroy)
  worker.jl              # Distributed worker lifecycle
  revise.jl              # Revise.jl integration (revise, track, includet, status)
  packages.jl            # Pkg actions, project activation
  logging.jl             # Log viewer functionality
  tools.jl               # MCP tool definitions (8 tools)
  server.jl              # start_server function
```

**Key Components:**

| Component | File | Description |
|-----------|------|-------------|
| `SessionState` | types.jl | Per-session state: worker ID, project path, Revise status |
| `SessionRegistry` | types.jl | Registry of all sessions with current-session tracking |
| `LogViewerState` | types.jl | Optional log viewer terminal state |
| `HighlightConfig` | types.jl | Syntax highlighting configuration |
| `ensure_worker!(session)` | worker.jl | Ensures worker exists for a session |
| `capture_eval_on_worker(code; session_name)` | worker.jl | Evaluates code with output capture |
| `reset_worker!(session)` | worker.jl | Kills and respawns a session's worker |
| `resolve_session(name)` | sessions.jl | Resolves optional session name to SessionState |
| `revise_on_worker!(session)` | revise.jl | Triggers Revise.revise() on worker |
| `activate_project_on_worker!(path; session_name)` | packages.jl | Switches worker environment |

All functions have docstrings accessible via `?function_name` in the Julia REPL.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history and release notes.

## License

Apache License 2.0 - See [LICENSE](LICENSE) for details.

## Contributing

Contributions welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on:
- Setting up the development environment
- Code style and documentation standards
- Pull request process
- Adding new features

## Acknowledgments

- [ModelContextProtocol.jl](https://github.com/JuliaSMLM/ModelContextProtocol.jl) - MCP framework
- [MCPRepl.jl](https://github.com/hexaeder/MCPRepl.jl) - Inspiration and prior art
- [Kaimon.jl](https://github.com/kahliburke/Kaimon.jl) - Comprehensive Julia agent toolkit
- [REPLicant.jl](https://github.com/MichaelHatherly/REPLicant.jl) - Alternative approach
- [Modern Julia Workflows](https://modernjuliaworkflows.org/) - Best practices guide
