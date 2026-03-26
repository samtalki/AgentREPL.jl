---
name: julia-evaluation
description: Activates when user asks to run, evaluate, or test Julia code in a persistent REPL session, or mentions Julia REPL, Julia session, or hot-reloading Julia changes.
version: 0.7.0
---

# Julia REPL — Behavioral Rules

Use the MCP tools (`eval`, `reset`, `pkg`, `activate`, `session`, `revise`, `log_viewer`, `info`) for interactive Julia work. Prefer `julia script.jl` via bash for one-shot scripts.

## Before Every Eval

Always display code in a readable julia code block BEFORE calling eval. The MCP permission prompt shows code as an escaped string which is unreadable.

## After Eval

MCP tool results are collapsed in Claude Code. If eval returns rich visual output (plots, tables, matrices, DataFrames, multi-line structured data), paste the complete output as raw text (NOT in a code block) to preserve ANSI colors. Do not paste simple scalars or errors.

## Revise vs Reset

Prefer `revise` — it preserves session state. Only `reset` when required.

| Change | Action |
|--------|--------|
| Function/method body or signature | `revise(action="revise")` |
| Struct layout (Julia < 1.12) | `reset` required |
| Corrupted state / stuck code | `reset` required |

After editing `.jl` files, call `revise(action="revise")` to hot-reload (the PostToolUse hook may do this automatically).

## Error Recovery

| Error | Fix |
|-------|-----|
| `UndefVarError` | Re-run definition or check spelling |
| `MethodError` | Check argument types |
| `LoadError` | `pkg(action="add", packages="...")` |
| `cannot redefine` | `reset` (struct layout change) |
| Hung/infinite | `eval(code=..., timeout=5)` or `reset` |

## First Use

On first Julia use in a conversation, ask which environment to activate (current directory, specific path, or global).

## Capabilities

- Sessions persist variables, functions, and packages across evals
- Multiple named sessions provide isolated workers
- `timeout` parameter kills hung code and respawns the worker
- `max_output` prevents context overflow from large results
- `isolated=true` evals in a fresh module without polluting Main
- `ephemeral=true` evals in a disposable temporary session
