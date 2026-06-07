---
name: julia-evaluation
description: Activates when user asks to run, evaluate, or test Julia code in a persistent REPL session, or mentions Julia REPL, Julia session, or hot-reloading Julia changes.
version: 0.7.1
---

# Julia REPL — Behavioral Rules

Use the MCP tools (`eval`, `reset`, `pkg`, `activate`, `session`, `revise`, `log_viewer`, `info`) for interactive Julia work. Prefer `julia script.jl` via bash for one-shot scripts.

## Before Every Eval

Always display code in a readable julia code block BEFORE calling eval. The MCP permission prompt shows code as an escaped string which is unreadable.

## After Eval

MCP tool results are collapsed in Claude Code. For visual output (plots, heatmaps), tell the user to expand the tool result (Ctrl+O) to see it with full color — do NOT paste ANSI art into your message (it loses colors and streams token-by-token). For structured text (tables, matrices, DataFrames), paste in a fenced code block. Do not paste simple scalars or errors.

## Revise vs Reset

Prefer `revise` — it preserves session state. Only `reset` when required.

| Change | Action |
|--------|--------|
| Function/method body or signature | `revise(action="revise")` |
| Struct layout (Julia < 1.12) | `reset` required |
| Corrupted state / stuck code | `reset` required |

After editing `.jl` files, call `revise(action="revise")` to hot-reload (a PostToolUse hook reminds you after `.jl` edits).

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
