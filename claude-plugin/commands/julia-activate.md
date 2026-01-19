---
name: julia-activate
description: Activate a Julia project/environment for the session
argument-hint: "<path>"
allowed-tools:
  - mcp__plugin_julia_julia-repl__activate
  - mcp__plugin_julia_julia-repl__pkg
---

# Julia Activate Command

Activate a Julia project or environment for the current session.

## Arguments

- `path` - Path to project directory, "." for current directory, or named environment like "@v1.10"

## Instructions

1. Parse the user's argument to determine the path:
   - If no argument or ".", activate the current working directory
   - If a path is given, use that path
   - If starts with "@", it's a named environment

2. Call `activate` with the path

3. After activation, offer to run `pkg(action="instantiate")` to install dependencies if the project has a Project.toml

## Examples

```
/julia-activate .
/julia-activate /path/to/MyProject
/julia-activate @v1.10
```

## Notes

- Activating a project changes where packages are installed/loaded from
- Use `pkg(action="instantiate")` after activation to install dependencies
- The activated environment persists across `reset` calls
- Use `info` to see the currently active project
