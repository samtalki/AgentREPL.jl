# AgentEval.jl

Persistent Julia code evaluation for AI agents via MCP (Model Context Protocol).

**The Problem:** Julia's "Time to First X" (TTFX) problem severely impacts AI agent workflows. Each `julia -e "..."` call incurs 1-2s startup + package loading + JIT compilation. AI agents like Claude Code spawn fresh Julia processes per command, wasting minutes of compute time.

**The Solution:** AgentEval provides a persistent Julia session via MCP STDIO transport. The Julia process stays alive, so you only pay the TTFX cost once.

## Why AgentEval?

| Feature | AgentEval | MCPRepl.jl | REPLicant.jl |
|---------|-----------|------------|--------------|
| Transport | **STDIO** | HTTP :3000 | TCP :8000+ |
| Auto-start | **Yes** | No (manual) | No (manual) |
| Network port | **None** | Yes | Yes |
| Registry eligible | **Yes** | No (security) | No |
| Persistent | Yes | Yes | Yes |
| Solves TTFX | Yes | Yes | Yes |

### Key Advantages

- **STDIO Transport**: No network port opened, more secure, can be registered in Julia General
- **Auto-spawns**: Claude Code starts AgentEval automatically when needed
- **Persistent State**: Variables, functions, and loaded packages survive across calls
- **Simple Setup**: One command to configure Claude Code

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/YOUR_USERNAME/AgentEval.jl")
```

Or for development:

```julia
Pkg.dev("https://github.com/YOUR_USERNAME/AgentEval.jl")
```

## Quick Start

### 1. Configure Claude Code

```bash
claude mcp add julia-eval -- julia --project=/path/to/AgentEval.jl -e "using AgentEval; AgentEval.start_server()"
```

Or using the provided script:

```bash
claude mcp add julia-eval -- julia --project=/path/to/AgentEval.jl /path/to/AgentEval.jl/bin/julia-eval-server
```

### 2. Use in Claude Code

Start a new Claude Code session. The Julia MCP server will auto-start when Claude needs it.

Ask Claude to run Julia code:
> "Calculate the first 10 Fibonacci numbers in Julia"

Claude will use the `julia_eval` tool, and the result will appear instantly after the first call (which may take a few seconds for JIT compilation).

## Tools Provided

### `julia_eval`

Evaluate Julia code in a persistent session.

```
# Example usage by Claude:
julia_eval(code = "x = 1 + 1")
# Result: 2

julia_eval(code = "x + 10")
# Result: 12 (x persists!)
```

Features:
- Variables and functions persist across calls
- Packages loaded once stay loaded
- Both return values and printed output are captured
- Errors are caught and reported with backtraces

### `julia_reset`

Soft reset: Clear user-defined variables.

```
julia_reset()
# Clears all user variables, but cannot redefine types
```

Note: Type redefinitions require restarting the Claude Code session.

### `julia_info`

Get session information.

```
julia_info()
# Julia Version: 1.10.x
# Active Project: /path/to/project
# User Variables: x, y, my_function
# Loaded Modules: 42
```

### `julia_pkg`

Manage Julia packages in the current environment.

```
# Add packages
julia_pkg(action="add", packages="JSON")
julia_pkg(action="add", packages="JSON, DataFrames, CSV")

# Remove packages
julia_pkg(action="rm", packages="OldPackage")

# Show package status
julia_pkg(action="status")

# Update all packages
julia_pkg(action="update")

# Update specific packages
julia_pkg(action="update", packages="JSON")
```

Actions:
- `add`: Install packages (packages parameter required)
- `rm`: Remove packages (packages parameter required)
- `status`: Show installed packages
- `update`: Update packages (all if packages not specified)

The `packages` parameter accepts space or comma-separated package names.

## Configuration

### Activate a Specific Project

Set the `JULIA_EVAL_PROJECT` environment variable:

```bash
JULIA_EVAL_PROJECT=/path/to/your/project claude mcp add julia-eval -- julia --project=/path/to/AgentEval.jl -e "using AgentEval; AgentEval.start_server()"
```

Or pass it directly:

```julia
AgentEval.start_server(project_dir="/path/to/your/project")
```

## Comparison with Alternatives

### vs ClaudeCodeSDK.jl

[ClaudeCodeSDK.jl](https://github.com/AtelierArith/ClaudeCodeSDK.jl) is an SDK for calling Claude Code **from** Julia. It's the opposite direction of AgentEval.

| Aspect | AgentEval | ClaudeCodeSDK.jl |
|--------|-----------|------------------|
| Direction | Claude → Julia | Julia → Claude |
| Purpose | Claude runs Julia code | Julia calls Claude |
| Use case | AI agent development | Automating Claude workflows |

**When to use ClaudeCodeSDK.jl**: You want to call Claude programmatically from Julia scripts or applications.

**When to use AgentEval**: You want Claude Code to execute Julia code in a persistent session.

### vs ModelContextProtocol.jl

[ModelContextProtocol.jl](https://github.com/JuliaSMLM/ModelContextProtocol.jl) is the MCP framework that AgentEval is built on. It provides the building blocks (`MCPTool`, `MCPResource`, `mcp_server`) for creating MCP servers.

| Aspect | AgentEval | ModelContextProtocol.jl |
|--------|-----------|-------------------------|
| Type | Ready-to-use MCP server | Framework for building servers |
| Setup | One command | Write custom tools |
| Flexibility | Julia eval only | Any tools you want |

**When to use ModelContextProtocol.jl**: You want to build custom MCP tools beyond code evaluation.

**When to use AgentEval**: You want persistent Julia evaluation without writing any MCP code.

### vs MCPRepl.jl

[MCPRepl.jl](https://github.com/hexaeder/MCPRepl.jl) is an excellent package that inspired AgentEval. Key differences:

| Aspect | AgentEval | MCPRepl.jl |
|--------|-----------|------------|
| Transport | STDIO | HTTP |
| Port required | No | Yes (:3000) |
| Manual startup | No | Yes |
| Shared REPL | No | Yes |
| Registry status | Eligible | Not eligible (security) |

**When to use MCPRepl.jl**: If you want to share a REPL with the AI agent (see each other's commands).

**When to use AgentEval**: If you want auto-start, no network port, or plan to distribute via Julia registry.

### vs REPLicant.jl

[REPLicant.jl](https://github.com/MichaelHatherly/REPLicant.jl) uses TCP sockets with a custom protocol (not MCP).

| Aspect | AgentEval | REPLicant.jl |
|--------|-----------|--------------|
| Protocol | MCP (standard) | Custom |
| Integration | `claude mcp add` | `just`/`nc` commands |
| Port required | No | Yes |

**When to use REPLicant.jl**: If you're using `just` for task automation.

**When to use AgentEval**: If you want standard MCP integration with Claude Code.

### vs DaemonMode.jl

[DaemonMode.jl](https://github.com/dmolina/DaemonMode.jl) is a client-daemon system for running Julia scripts faster.

| Aspect | AgentEval | DaemonMode.jl |
|--------|-----------|---------------|
| Protocol | MCP | Custom |
| Port required | No | Yes (:3000) |
| Julia 1.10+ | Yes | Broken |
| AI integration | Native | Requires wrapper |

**When to use DaemonMode.jl**: For general script acceleration (if using older Julia).

**When to use AgentEval**: For AI agent integration with modern Julia.

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
using AgentEval
AgentEval.start_server()  # Blocks, waiting for MCP messages on stdin
```

## License

Apache License 2.0 - See [LICENSE](LICENSE) for details.

## Contributing

Contributions welcome! Please open an issue or PR on GitHub.

## Acknowledgments

- [ModelContextProtocol.jl](https://github.com/JuliaSMLM/ModelContextProtocol.jl) - MCP framework
- [MCPRepl.jl](https://github.com/hexaeder/MCPRepl.jl) - Inspiration and prior art
- [REPLicant.jl](https://github.com/MichaelHatherly/REPLicant.jl) - Alternative approach
