---
name: julia-develop
description: Set up a Julia development workflow with Revise hot-reloading
argument-hint: "[path]"
allowed-tools:
  - mcp__plugin_julia_julia-repl__activate
  - mcp__plugin_julia_julia-repl__pkg
  - mcp__plugin_julia_julia-repl__eval
  - mcp__plugin_julia_julia-repl__revise
  - mcp__plugin_julia_julia-repl__info
---

# Julia Development Workflow

Set up a complete Julia development workflow with project activation, dependency installation, and Revise.jl hot-reloading.

## Arguments

- `path` - Path to the project directory (default: current directory ".")

## Instructions

Execute these steps in sequence:

1. **Activate the project**:
   ```
   activate(path="<path>")
   ```

2. **Install dependencies**:
   ```
   pkg(action="instantiate")
   ```

3. **Load the package** (if it's a Julia package with `src/<PkgName>.jl`):
   ```
   eval(code="using <PkgName>")
   ```

4. **Verify Revise.jl is available**:
   ```
   revise(action="status")
   ```
   If Revise is not available:
   ```
   pkg(action="add", packages="Revise")
   ```
   Then reset to reload (Revise auto-loads on startup).

5. **Report the setup** to the user:
   - Project path
   - Installed dependencies
   - Package loaded
   - Revise.jl status
   - Ready for iterative development

## Development Cycle

Once set up, the iterative development cycle is:

1. **Edit source files** — Claude edits `.jl` files as needed
2. **Hot-reload** — `revise(action="revise")` picks up changes
3. **Test** — `eval` to run code, or `pkg(action="test")` for full test suite
4. **Repeat** — no session restart needed

## For Package Development

When developing a local package alongside a project:

```
pkg(action="develop", packages="./path/to/MyPkg")
```

This puts the package in development mode. Combined with Revise, any edits to the package source are automatically picked up without restarting.

When done:
```
pkg(action="free", packages="MyPkg")
```
