#!/usr/bin/env bash
# PostToolUse(Write|Edit): if a .jl file was edited, remind the model to hot-reload via the
# revise MCP tool. Non-blocking — emits additionalContext only; never blocks or halts.
set -euo pipefail
payload="$(cat)"
if printf '%s' "$payload" | grep -qE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*\.jl"'; then
  printf '%s' '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"A .jl file was edited. If a Julia REPL session is active, call the revise MCP tool with action=revise to hot-reload the change without losing session state."}}'
fi
