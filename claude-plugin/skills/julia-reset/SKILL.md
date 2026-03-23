---
name: julia-reset
description: Kill and respawn the Julia worker (hard reset)
argument-hint: "[session-name]"
allowed-tools:
  - mcp__plugin_julia_julia-repl__reset
---

# Julia Reset

Kill the Julia worker process and spawn a fresh one (hard reset).

## What This Does

This is a **hard reset** that:
- Kills the worker process entirely
- Spawns a fresh Julia worker
- Clears all variables, functions, and loaded packages
- **Enables type/struct redefinitions** (necessary in Julia < 1.12)
- Re-activates the previously activated project
- Reloads Revise.jl if available

## Instructions

1. If the user provides a session name argument, pass it as the `session` parameter
2. Call the `reset` MCP tool
3. Report the old and new worker IDs to the user
4. Remind the user that packages need to be reloaded with `using`

## When to Use

- You need to redefine a struct layout (Julia < 1.12)
- The session is in a bad/corrupted state
- You want a completely clean slate
- Code is stuck/hanging (infinite loop, long computation)

## When NOT to Use

- For function/method changes: use `revise(action="revise")` instead — it preserves session state
- For package issues: try `pkg(action="resolve")` first
