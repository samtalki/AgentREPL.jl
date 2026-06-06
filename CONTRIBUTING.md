# Contributing to AgentREPL.jl

Thank you for your interest in contributing to AgentREPL.jl! This document provides guidelines and information for contributors.

## Getting Started

### Prerequisites

- Julia 1.12 or later
- Git
- (Optional) Claude Code for testing the MCP integration

### Setting Up the Development Environment

1. Clone the repository:
   ```bash
   git clone https://github.com/samtalki/AgentREPL.jl.git
   cd AgentREPL.jl
   ```

2. Install dependencies:
   ```julia
   using Pkg
   Pkg.activate(".")
   Pkg.instantiate()
   ```

3. Run the tests to ensure everything works:
   ```bash
   julia --project=. -e "using Pkg; Pkg.test()"
   ```

## Development Workflow

### Running Tests

```bash
# Run all tests
julia --project=. -e "using Pkg; Pkg.test()"

# Run a specific test file
julia --project=. test/test_eval.jl
```

### Testing the MCP Server Locally

```bash
# Start the server manually (for debugging)
julia --project=. -e "using AgentREPL; AgentREPL.start_server()"

# With a specific project activated
JULIA_REPL_PROJECT=/path/to/project julia --project=. bin/julia-repl-server
```

### Testing the Claude Code Plugin

```bash
# Run Claude Code with the local plugin
claude --plugin-dir ./claude-plugin
```

## Code Style

### Julia Code

- Follow the [Julia Style Guide](https://docs.julialang.org/en/v1/manual/style-guide/)
- Use 4-space indentation
- Add docstrings to all public functions and types
- Keep functions focused and reasonably sized

### Docstrings

All exported functions should have docstrings following Julia conventions:

```julia
"""
    function_name(arg1, arg2; kwarg=default) -> ReturnType

Brief description of what the function does.

# Arguments
- `arg1`: Description of arg1
- `arg2`: Description of arg2

# Keywords
- `kwarg=default`: Description of kwarg

# Returns
Description of return value.

# Examples
```julia
result = function_name(1, 2)
```
"""
function function_name(arg1, arg2; kwarg=default)
    # implementation
end
```

### Commit Messages

- Use clear, descriptive commit messages
- Start with a verb in imperative mood (e.g., "Add", "Fix", "Update")
- Keep the first line under 72 characters
- Reference issues when applicable (e.g., "Fix #123")

Examples:
- `Add Pkg.test support for running package tests`
- `Fix shared environment activation for @v1.10 syntax`
- `Update documentation for worker subprocess model`

## Pull Request Process

1. **Fork** the repository and create your branch from `main`

2. **Make your changes**:
   - Write clean, documented code
   - Add tests for new functionality
   - Update documentation as needed

3. **Test your changes**:
   ```bash
   julia --project=. -e "using Pkg; Pkg.test()"
   ```

4. **Update the CHANGELOG**:
   - Add your changes under the `[Unreleased]` section
   - Follow the existing format

5. **Submit a Pull Request**:
   - Provide a clear description of the changes
   - Reference any related issues
   - Ensure CI passes

## Architecture Overview

Understanding the architecture will help you contribute effectively:

### Worker Subprocess Model

AgentREPL uses [Malt.jl](https://github.com/JuliaPluto/Malt.jl) to spawn a worker subprocess:

```
Main Process (MCP Server)
    ↕ Malt.remote_eval_fetch (via _remote_eval_fetch)
Worker Process (Code Evaluation)
```

Key benefits:
- True hard reset (kill worker, spawn new one)
- Type redefinition support
- Environment persistence across resets

### Key Files

| File | Purpose |
|------|---------|
| `src/AgentREPL.jl` | Main module (imports, includes, exports) |
| `src/types.jl` | State structs (SessionState, SessionRegistry, etc.) |
| `src/tools.jl` | MCP tool definitions (8 tools) |
| `src/sessions.jl` | Multi-session lifecycle management |
| `src/worker.jl` | Malt worker lifecycle |
| `src/revise.jl` | Revise.jl integration |
| `src/highlighting.jl` | Syntax highlighting |
| `src/formatting.jl` | Result formatting, stacktrace truncation |
| `src/packages.jl` | Pkg actions, project activation |
| `src/logging.jl` | Log viewer functionality |
| `src/server.jl` | start_server function |
| `bin/julia-repl-server` | Entry point script |
| `test/` | Tests (test_eval, test_sessions, test_highlighting, test_revise) |
| `claude-plugin/` | Claude Code plugin (skills, hooks) |

### Important Functions

- `ensure_worker!(session)` - Ensures worker exists for a session, creates if needed
- `capture_eval_on_worker(code; timeout, session_name)` - Evaluates code with output capture
- `reset_worker!(session)` - Kills session's worker and spawns fresh one
- `resolve_session(session_name)` - Resolves optional session name to SessionState
- `create_session!(name)` / `switch_session!(name)` / `destroy_session!(name)` - Session lifecycle
- `revise_on_worker!(session)` - Triggers Revise.revise() on worker
- `activate_project_on_worker!(path; session_name)` - Switches environment
- `start_server()` - Entry point, registers MCP tools

## Adding New Features

### Adding a New MCP Tool

1. Define a `create_<toolname>_tool()` function in `src/tools.jl` that returns an `MCPTool`:
   ```julia
   function create_mytool_tool()
       MCPTool(
           name = "mytool",
           description = "...",
           parameters = [...],
           handler = params -> begin
               # implementation
           end
       )
   end
   ```
   See `create_eval_tool()` in `src/tools.jl` for the pattern.

2. Call it from `start_server()` in `src/server.jl` and add it to the `tools` list in `mcp_server()`

3. Add tests (e.g., `test/test_mytool.jl`)

4. Document in README.md

### Adding a New Pkg Action

1. Add the action to `run_pkg_action_on_worker()`
2. Update the `pkg_tool` description and validation
3. Add tests
4. Update documentation

## Reporting Issues

When reporting issues, please include:

- Julia version (`julia --version`)
- AgentREPL version (from Project.toml)
- Operating system
- Steps to reproduce
- Expected vs actual behavior
- Error messages/stack traces if applicable

## Questions?

- Open an issue for questions about contributing
- Check existing issues and PRs for similar discussions

## License

By contributing, you agree that your contributions will be licensed under the Apache License 2.0.
