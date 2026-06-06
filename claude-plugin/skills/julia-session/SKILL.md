---
name: julia-session
description: Manage multiple Julia REPL sessions (create, switch, list, destroy)
argument-hint: "<action> [name]"
allowed-tools:
  - mcp__plugin_julia_julia-repl__session
  - mcp__plugin_julia_julia-repl__info
---

# Julia Session Management

Manage multiple concurrent Julia REPL sessions. Each session has its own isolated worker process with separate state, packages, and project environment.

## Arguments

- `action` - One of: `create`, `switch`, `list`, `destroy`
- `name` - Session name (required for create/switch/destroy)

## Instructions

Parse the user's arguments:

| User Input | Action | Name |
|------------|--------|------|
| `create analysis` | create | analysis |
| `switch testing` | switch | testing |
| `list` | list | (none) |
| `destroy old-session` | destroy | old-session |

Call `session` with the appropriate action and name parameters.

## When to Create Separate Sessions

- **Development + Testing**: One session for development work, another for running tests
- **Multiple Projects**: One session per project when working across repos
- **Benchmarking**: Isolate benchmark runs from development state
- **Experimentation**: Try something risky without affecting your main session

## Session Lifecycle

1. Sessions start with no worker — workers spawn lazily on first `eval`
2. Each session gets its own Malt.jl worker process
3. Variables, packages, and project environment are fully isolated between sessions
4. Revise.jl is auto-loaded on each worker if available
5. The "default" session is auto-created if you use `eval` without creating a session first

## Notes

- Session names should be short, descriptive identifiers (e.g., "dev", "test", "analysis")
- Use `list` to see all sessions with their worker status, project, and Revise availability
- The `*` marker in list output indicates the current session
- Destroying a session kills its worker process immediately
- If you destroy the current session, another session becomes current automatically
