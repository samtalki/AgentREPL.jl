---
name: julia-mode
description: Switch between distributed and tmux REPL modes
allowed_tools:
  - mcp__plugin_julia_julia-repl__mode
---

# Julia Mode Switching

Switch REPL execution mode using the `mode` tool.

## Modes

- **distributed** (default): Headless worker subprocess via Distributed.jl
- **tmux**: Visible terminal with bidirectional Julia REPL (you can type directly)

## Usage

$ARGUMENTS is the target mode: `tmux` or `distributed`

Call the mode tool with the requested mode.
