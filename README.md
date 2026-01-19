# AgentREPL.jl

Persistent Julia REPL for AI agents via MCP (Model Context Protocol).

**The Problem:** Julia's "Time to First X" (TTFX) problem severely impacts AI agent workflows. Each `julia -e "..."` call incurs 1-2s startup + package loading + JIT compilation. AI agents like Claude Code spawn fresh Julia processes per command, wasting minutes of compute time.

**The Solution:** AgentREPL provides a persistent Julia session via MCP STDIO transport. The Julia process stays alive, so you only pay the TTFX cost once.

## Why AgentREPL?

| Feature | AgentREPL | MCPRepl.jl | REPLicant.jl |
|---------|-----------|------------|--------------|
| Transport | **STDIO** | HTTP :3000 | TCP :8000+ |
| Auto-start | **Yes** | No (manual) | No (manual) |
| Network port | **None** | Yes | Yes |
| True hard reset | **Yes** | No | No |
| Type redefinition | **Yes** | No | No |
| Test support | **Yes** | No | No |
| Pkg.develop support | **Yes** | No | No |
| Registry eligible | **Yes** | No (security) | No |
| Persistent | Yes | Yes | Yes |
| Solves TTFX | Yes | Yes | Yes |

### Key Advantages

- **STDIO Transport**: No network port opened, more secure, can be registered in Julia General
- **Auto-spawns**: Claude Code starts AgentREPL automatically when needed
- **Persistent State**: Variables, functions, and loaded packages survive across calls
- **True Hard Reset**: Worker subprocess model allows type redefinitions without restarting Claude Code
- **Modern Workflows**: Built-in support for `Pkg.test`, `Pkg.develop`, and `Pkg.free`
- **Simple Setup**: Use the plugin for zero-config, or one command for manual setup

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
- Slash commands: `/julia-reset`, `/julia-info`, `/julia-pkg`, `/julia-activate`
- Best practices skill for Julia development

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

AgentREPL uses a **worker subprocess model** via Distributed.jl:

```
┌─────────────────────────────────────────────────────┐
│ Claude Code                                          │
│   ↕ STDIO (MCP)                                      │
│ ┌─────────────────────────────────────────────────┐ │
│ │ AgentREPL MCP Server (Main Process)             │ │
│ │   ↕ Distributed.jl                              │ │
│ │ ┌─────────────────────────────────────────────┐ │ │
│ │ │ Worker Process (code evaluation happens here)│ │ │
│ │ └─────────────────────────────────────────────┘ │ │
│ └─────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

**Why a worker subprocess?**
- `reset` can kill and respawn the worker for a **true hard reset**
- Type/struct redefinitions work (impossible with in-process reset)
- The activated environment persists across resets
- Worker is spawned lazily on first use to avoid STDIO conflicts

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

### `mode` (Deprecated)

Switch between execution modes at runtime. **Not recommended** - tmux mode has unfixable issues.

```
mode(mode="distributed")   # Default, recommended
mode(mode="tmux")          # Deprecated - use log_viewer instead
```

Use distributed mode with `log_viewer` for visual output.

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

## Comparison with Alternatives

### vs Auton.jl

[Auton.jl](https://github.com/AntonOresten/Auton.jl) provides LLM-augmented REPL modes for human-in-the-loop workflows.

| Aspect | AgentREPL | Auton.jl |
|--------|-----------|----------|
| Use case | AI agent automation | Human + LLM collaboration |
| Operator | AI agent (autonomous) | Human at keyboard |
| Interface | MCP tools (headless) | REPL modes (interactive) |
| LLM integration | Claude Code built-in | PromptingTools.jl (any model) |
| Setup | Plugin or one command | Startup.jl config |

**When to use Auton.jl**: You want LLM assistance while *you* work in the Julia REPL—context-aware suggestions, code generation, and iterative refinement with you in control.

**When to use AgentREPL**: You want Claude Code to execute Julia code autonomously as part of a larger AI agent workflow, without requiring human presence at the REPL.

### vs ClaudeCodeSDK.jl

[ClaudeCodeSDK.jl](https://github.com/AtelierArith/ClaudeCodeSDK.jl) is an SDK for calling Claude Code **from** Julia. It's the opposite direction of AgentREPL.

| Aspect | AgentREPL | ClaudeCodeSDK.jl |
|--------|-----------|------------------|
| Direction | Claude → Julia | Julia → Claude |
| Purpose | Claude runs Julia code | Julia calls Claude |
| Use case | AI agent development | Automating Claude workflows |

**When to use ClaudeCodeSDK.jl**: You want to call Claude programmatically from Julia scripts or applications.

**When to use AgentREPL**: You want Claude Code to execute Julia code in a persistent session.

### vs ModelContextProtocol.jl

[ModelContextProtocol.jl](https://github.com/JuliaSMLM/ModelContextProtocol.jl) is the MCP framework that AgentREPL is built on. It provides the building blocks (`MCPTool`, `MCPResource`, `mcp_server`) for creating MCP servers.

| Aspect | AgentREPL | ModelContextProtocol.jl |
|--------|-----------|-------------------------|
| Type | Ready-to-use MCP server | Framework for building servers |
| Setup | One command | Write custom tools |
| Flexibility | Julia REPL only | Any tools you want |

**When to use ModelContextProtocol.jl**: You want to build custom MCP tools beyond code evaluation.

**When to use AgentREPL**: You want persistent Julia evaluation without writing any MCP code.

### vs MCPRepl.jl

[MCPRepl.jl](https://github.com/hexaeder/MCPRepl.jl) is an excellent package that inspired AgentREPL. Key differences:

| Aspect | AgentREPL | MCPRepl.jl |
|--------|-----------|------------|
| Transport | STDIO | HTTP |
| Port required | No | Yes (:3000) |
| Manual startup | No | Yes |
| Shared REPL | No | Yes |
| Registry status | Eligible | Not eligible (security) |

**When to use MCPRepl.jl**: If you want to share a REPL with the AI agent (see each other's commands).

**When to use AgentREPL**: If you want auto-start, no network port, or plan to distribute via Julia registry.

### vs REPLicant.jl

[REPLicant.jl](https://github.com/MichaelHatherly/REPLicant.jl) uses TCP sockets with a custom protocol (not MCP).

| Aspect | AgentREPL | REPLicant.jl |
|--------|-----------|--------------|
| Protocol | MCP (standard) | Custom |
| Integration | `claude mcp add` | `just`/`nc` commands |
| Port required | No | Yes |

**When to use REPLicant.jl**: If you're using `just` for task automation.

**When to use AgentREPL**: If you want standard MCP integration with Claude Code.

### vs DaemonMode.jl

[DaemonMode.jl](https://github.com/dmolina/DaemonMode.jl) is a client-daemon system for running Julia scripts faster.

| Aspect | AgentREPL | DaemonMode.jl |
|--------|-----------|---------------|
| Protocol | MCP | Custom |
| Port required | No | Yes (:3000) |
| Julia 1.10+ | Yes | Broken |
| AI integration | Native | Requires wrapper |

**When to use DaemonMode.jl**: For general script acceleration (if using older Julia).

**When to use AgentREPL**: For AI agent integration with modern Julia.

## Claude Code Plugin

The `claude-plugin/` directory contains a ready-to-use Claude Code plugin that provides:

### Auto-configured MCP Server
No need to manually run `claude mcp add`. The plugin configures the Julia MCP server automatically.

### Slash Commands
| Command | Description |
|---------|-------------|
| `/julia-reset` | Kill and respawn the Julia worker (hard reset) |
| `/julia-info` | Show session information |
| `/julia-pkg <action> [packages]` | Package management |
| `/julia-activate <path>` | Activate a project/environment |

### Best Practices Skill
The included skill teaches Claude:
- Always display code before calling `eval` (for readable permission prompts)
- First-time environment setup dialogue
- When to use hard reset vs. continuing
- Testing and development workflows
- Error handling patterns

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

For visual output, set `JULIA_REPL_VIEWER=auto` to open a terminal showing real-time Julia output.

### Internal Architecture

For developers extending AgentREPL:

**File Structure:**
```
src/
  AgentREPL.jl           # Main module (imports, includes, exports)
  types.jl               # State structs (WorkerState, LogViewerState, etc.)
  formatting.jl          # Result formatting, stacktrace truncation
  worker.jl              # Distributed worker lifecycle
  packages.jl            # Pkg actions, project activation
  logging.jl             # Log viewer functionality
  tools.jl               # MCP tool definitions
  server.jl              # start_server function
  deprecated/
    tmux.jl              # Deprecated tmux bidirectional REPL
```

**Key Components:**

| Component | File | Description |
|-----------|------|-------------|
| `WorkerState` | types.jl | Manages worker subprocess ID and project path |
| `LogViewerState` | types.jl | Manages optional log viewer terminal |
| `TmuxREPLState` | types.jl | State for deprecated tmux mode |
| `ensure_worker!()` | worker.jl | Ensures worker exists, spawns if needed |
| `capture_eval_on_worker(code)` | worker.jl | Evaluates code with output capture |
| `reset_worker!()` | worker.jl | Kills and respawns worker |
| `activate_project_on_worker!(path)` | packages.jl | Switches worker environment |

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
- [REPLicant.jl](https://github.com/MichaelHatherly/REPLicant.jl) - Alternative approach
- [Modern Julia Workflows](https://modernjuliaworkflows.org/) - Best practices guide
