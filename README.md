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

Claude will use the `eval` tool, and the result will appear instantly after the first call (which may take a few seconds for JIT compilation).

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

Evaluate Julia code in a persistent session.

```
# Example usage by Claude:
eval(code = "x = 1 + 1")
# Result: 2

eval(code = "x + 10")
# Result: 12 (x persists!)
```

Features:
- Variables and functions persist across calls
- Packages loaded once stay loaded
- Both return values and printed output are captured
- Errors are caught and reported with backtraces

### `reset`

**Hard reset**: Kills the worker process and spawns a fresh one.

```
reset()
# Worker killed and respawned - complete clean slate
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
info()
# Julia Version: 1.10.x
# Active Project: /path/to/project
# User Variables: x, y, my_function
# Loaded Modules: 42
# Worker ID: 2
```

### `activate`

Switch the active Julia project/environment.

```
# Activate current directory
activate(path=".")

# Activate a specific project
activate(path="/path/to/MyProject")

# Activate a named shared environment
activate(path="@v1.10")
```

After activation, install dependencies with:
```
pkg(action="instantiate")
```

### `pkg`

Manage Julia packages in the current environment.

```
# Add packages
pkg(action="add", packages="JSON")
pkg(action="add", packages="JSON, DataFrames, CSV")

# Remove packages
pkg(action="rm", packages="OldPackage")

# Show package status
pkg(action="status")

# Update all packages
pkg(action="update")

# Update specific packages
pkg(action="update", packages="JSON")

# Install dependencies from Project.toml/Manifest.toml
pkg(action="instantiate")

# Resolve dependency graph
pkg(action="resolve")

# Run tests
pkg(action="test")                     # Test current project
pkg(action="test", packages="MyPkg")   # Test specific package

# Development workflow
pkg(action="develop", packages="./MyLocalPackage")  # Use local code
pkg(action="free", packages="MyPackage")            # Return to registry
```

Actions:
- `add`: Install packages (packages parameter required)
- `rm`: Remove packages (packages parameter required)
- `status`: Show installed packages
- `update`: Update packages (all if packages not specified)
- `instantiate`: Download and precompile all dependencies from Project.toml/Manifest.toml
- `resolve`: Resolve dependency graph and update Manifest.toml
- `test`: Run package tests (current project if no packages specified)
- `develop`: Put packages in development mode (use local code)
- `free`: Exit development mode (return to registry version)

The `packages` parameter accepts space or comma-separated package names.

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

## License

Apache License 2.0 - See [LICENSE](LICENSE) for details.

## Contributing

Contributions welcome! Please open an issue or PR on GitHub.

## Acknowledgments

- [ModelContextProtocol.jl](https://github.com/JuliaSMLM/ModelContextProtocol.jl) - MCP framework
- [MCPRepl.jl](https://github.com/hexaeder/MCPRepl.jl) - Inspiration and prior art
- [REPLicant.jl](https://github.com/MichaelHatherly/REPLicant.jl) - Alternative approach
- [Modern Julia Workflows](https://modernjuliaworkflows.org/) - Best practices guide
