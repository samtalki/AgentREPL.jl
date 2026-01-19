# Julia Plugin for Claude Code

This plugin provides a persistent Julia REPL for Claude Code, eliminating the "Time to First X" (TTFX) startup penalty that normally occurs with each Julia invocation.

## Prerequisites

- Julia 1.10+ installed and available in PATH
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

### MCP Server

The plugin automatically configures the `julia-repl` MCP server which provides:

- `eval` - Evaluate Julia code with persistent state
- `reset` - **Hard reset**: kills worker, spawns fresh one
- `info` - Get session information (including worker ID)
- `pkg` - Manage packages (add, rm, status, update, instantiate, resolve, test, develop, free)
- `activate` - Switch project/environment

### Commands

- `/julia-reset` - Kill and respawn the Julia worker (true reset)
- `/julia-info` - Show session information
- `/julia-pkg <action> [packages]` - Package management
- `/julia-activate <path>` - Activate a project/environment

### Skill

The `julia-evaluation` skill provides best practices guidance for:
- Showing code before evaluation (for readable permission prompts)
- Understanding TTFX behavior
- Working with session persistence
- Environment management
- Testing and development workflows
- When to use hard reset vs continuing

## Architecture

AgentREPL uses a **worker subprocess model**:
- The MCP server runs in the main Julia process
- Code evaluation happens in a spawned worker (via Distributed.jl)
- `reset` kills the worker and spawns a fresh one
- This enables true reset including type redefinitions

## Usage

Once installed, simply ask Claude to run Julia code:

> "Calculate the first 20 Fibonacci numbers in Julia"

On first use, Claude will ask about your environment preference:
1. Current directory (activate Project.toml if present)
2. Specific project path
3. Default/global environment

## Session Behavior

- Variables, functions, and packages persist across evaluations
- `reset` provides a true hard reset (kills worker process)
- Type definitions CAN be changed after reset (unlike soft resets)
- Activated environment persists even across reset
- First evaluation is slow (TTFX), subsequent ones are fast

## Package Management

The `pkg` tool supports these actions:

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

## Development Workflow

For local package development:

```
# Put package in develop mode
/julia-pkg develop ./MyLocalPackage

# Make changes to the source code...

# Test your changes
/julia-pkg test MyLocalPackage

# When done, return to registry version
/julia-pkg free MyLocalPackage
```
