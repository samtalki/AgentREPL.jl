---
name: julia-reset
description: Kill and respawn the Julia worker (hard reset)
allowed-tools:
  - mcp__plugin_julia_julia-repl__reset
---

# Julia Reset Command

Kill the Julia worker process and spawn a fresh one (hard reset).

## What This Does

Unlike a "soft reset" that only clears variables, this is a **hard reset** that:
- Kills the worker process entirely
- Spawns a fresh Julia worker
- Clears all variables, functions, and loaded packages
- **Enables type/struct redefinitions** (impossible with soft reset)
- Re-activates the previously activated project

## Instructions

1. Call the `reset` MCP tool
2. Report the old and new worker IDs to the user
3. Remind the user that packages need to be reloaded with `using`

## When to Use

- You need to redefine a struct or type
- The session is in a bad/corrupted state
- You want a completely clean slate
- Something is behaving unexpectedly
