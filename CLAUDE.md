# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AgentEval.jl is a Julia package providing persistent code evaluation for AI agents via MCP (Model Context Protocol) STDIO transport. It solves Julia's "Time to First X" (TTFX) problem by maintaining a persistent Julia session, avoiding the 1-2 second startup penalty for each command.

## Build and Test Commands

```bash
# Run all tests
julia --project=. -e "using Pkg; Pkg.test()"

# Run a specific test file directly
julia --project=. test/test_eval.jl

# Start the MCP server manually (for debugging)
julia --project=. -e "using AgentEval; AgentEval.start_server()"

# Start server with a specific project activated
JULIA_EVAL_PROJECT=/path/to/project julia --project=. bin/julia-eval-server
```

## Architecture

### Single Module Design

The entire package lives in `src/AgentEval.jl` (~300 lines) with:

- **`capture_eval(code)`** - Evaluates Julia code in the Main module, capturing stdout/stderr and returning (value, output, error, backtrace)
- **`format_result(value, output, err, bt)`** - Formats evaluation results for display
- **`get_user_symbols()`** - Discovers user-defined symbols (filtering out protected internals)
- **`start_server()`** - Entry point that registers MCP tools and starts the server

### MCP Tools

Four tools registered via ModelContextProtocol.jl:

1. **`julia_eval`** - Evaluates arbitrary Julia code with persistent state
2. **`julia_reset`** - Clears user-defined variables (cannot reset type definitions)
3. **`julia_info`** - Returns session metadata (Julia version, project, variables, modules)
4. **`julia_pkg`** - Package management (add, rm, status, update)

### Key Design Decisions

- **Main module evaluation**: Code runs in `Main` so variables persist across calls
- **STDIO transport only**: No network ports for security
- **Protected symbols**: `PROTECTED_SYMBOLS` set prevents clearing Julia internals
- **Cannot redefine types**: Julia limitation; requires session restart

## Testing

Tests are in `test/test_eval.jl` covering:
- Code evaluation (arithmetic, variables, functions, multi-line)
- Output capture and error handling
- Result formatting
- Symbol management and protected symbol validation

## Entry Point

`bin/julia-eval-server` is the executable script that loads the module and calls `start_server()`. It accepts `JULIA_EVAL_PROJECT` environment variable to activate a specific project.
