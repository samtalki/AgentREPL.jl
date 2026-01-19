---
name: julia-info
description: Show Julia session information (version, project, variables, loaded modules)
allowed-tools:
  - mcp__plugin_julia_julia-repl__info
---

# Julia Info Command

Display information about the current Julia session.

## Instructions

1. Call the `info` MCP tool
2. Present the information clearly to the user:
   - Julia version
   - Active project path
   - User-defined variables
   - Number of loaded modules
   - Worker process ID

## Use Cases

- Check what variables exist from previous work
- Verify which Julia version is running
- See the active project environment
- Confirm the worker is alive and which ID it has
