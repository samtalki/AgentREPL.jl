---
name: julia-log
description: Control the log viewer for real-time Julia output
argument-hint: "<mode>"
allowed-tools:
  - mcp__plugin_julia_julia-repl__log_viewer
---

# Julia Log Viewer Command

Control the log viewer that displays Julia output in a separate terminal window.

## Arguments

- `mode` - One of: `auto`, `tmux`, `file`, `off`

## Modes

| Mode | Description |
|------|-------------|
| `auto` | Automatically choose the best viewer (tmux if available, otherwise file) |
| `tmux` | Open a tmux pane showing live output |
| `file` | Write output to `~/.julia/logs/repl.log` (view with `tail -f`) |
| `off` | Disable the log viewer |

## Instructions

1. Parse the user's argument to determine the mode
2. Call `log_viewer` with the specified mode
3. Report the result to the user

## Examples

```
/julia-log auto
/julia-log off
```

## Notes

- The log viewer shows `stdout` and `stderr` from eval calls in real-time
- Useful for long-running computations where you want to see progress
- `auto` is the recommended mode for most users
