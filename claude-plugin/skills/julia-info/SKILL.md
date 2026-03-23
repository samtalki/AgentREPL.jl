---
name: julia-info
description: Show Julia session information (version, project, variables, loaded modules, Revise status)
argument-hint: "[session-name]"
allowed-tools:
  - mcp__plugin_julia_julia-repl__info
---

# Julia Info

Display information about the current Julia session.

## Instructions

1. If the user provides a session name argument, pass it as the `session` parameter
2. Call the `info` MCP tool
3. Present the information clearly to the user:
   - Session name and current status
   - Julia version
   - Active project path
   - Revise.jl availability
   - User-defined variables with types and sizes
   - Number of loaded modules
   - Worker process ID

## Use Cases

- Check what variables exist from previous work
- Verify which Julia version is running
- See the active project environment
- Check if Revise.jl is loaded
- Confirm the worker is alive and which ID it has
