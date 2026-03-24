---
name: julia-revise
description: Hot-reload Julia code changes using Revise.jl without restarting the session
argument-hint: "[track <path>]"
allowed-tools:
  - mcp__plugin_julia_julia-repl__revise
  - mcp__plugin_julia_julia-repl__eval
  - mcp__plugin_julia_julia-repl__pkg
---

# Julia Revise (Hot-Reload)

Hot-reload Julia code changes using Revise.jl — the key to maximizing REPL session lifespan.

## Arguments

- No argument: triggers `revise(action="revise")` to pick up all file changes
- `track <path>`: starts tracking a file with Revise
- `includet <path>`: includes a file with Revise tracking
- `status`: shows what Revise is tracking

## Instructions

1. Parse the user's argument to determine the action and optional path
2. Call `revise` with the appropriate action and path parameters
3. If Revise is not available, offer to install it:
   - `pkg(action="add", packages="Revise")`
   - Then `reset` to reload (Revise loads automatically on worker startup)

## Revise Workflow

Revise.jl enables iterative development without losing session state:

1. **Edit Julia source files** (using Claude's Edit/Write tools)
2. **Call `revise(action="revise")`** to pick up changes
3. **Continue working** — all variables, data, and packages are preserved

This eliminates the most common reason for using `reset`.

## When to Use Revise vs Reset

| Situation | Use Revise | Use Reset |
|-----------|-----------|-----------|
| Changed function body | Yes | No |
| Added new function | Yes | No |
| Modified method signature | Yes | No |
| Changed struct **layout** (Julia < 1.12) | No | Yes |
| Corrupted session state | No | Yes |
| Want clean slate | No | Yes |
| Changed const value | Sometimes | If needed |

## Tips

- Revise.jl is auto-loaded on worker startup if installed in the environment
- After `pkg(action="develop", packages="./MyPkg")`, Revise automatically tracks the package source
- Use `includet("file.jl")` (via eval) instead of `include("file.jl")` for standalone scripts — it enables hot-reloading
- Call `revise(action="status")` to see what files and packages Revise is watching
