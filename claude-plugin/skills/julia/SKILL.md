---
name: julia-evaluation
description: This skill should be used when the user asks to "run Julia code", "evaluate Julia", "use Julia", "test Julia package", "add Julia package", "Julia REPL", mentions "persistent Julia session", "TTFX", "JIT compilation", or wants to work with Julia for data analysis, scientific computing, numerical computing, linear algebra, differential equations, machine learning, optimization, or package development. Also activates when user mentions Julia-specific concepts like "multiple dispatch", "type system", "metaprogramming", "macro", "DataFrames", "Plots", "Flux", or any Julia package names. Activates for Revise.jl hot-reloading, multi-session management, and Julia development workflows.
version: 0.6.0
---

# Julia Development Best Practices

This skill provides comprehensive guidance for using the persistent Julia REPL via MCP tools. AgentREPL maintains worker subprocesses for code evaluation, eliminating the "Time to First X" (TTFX) startup penalty. Multiple named sessions can run concurrently with isolated state.

## Architecture

AgentREPL uses a **multi-session distributed worker model**:
- The MCP server runs in the main process (STDIO transport)
- Each session has its own worker process (via Distributed.jl)
- Workers persist across calls — variables, functions, and packages stay loaded
- Revise.jl is auto-loaded on workers for hot-reloading code changes
- `reset` kills a session's worker and spawns a fresh one (true hard reset)

### Visual Output with Log Viewer

To see Julia output as it happens:
```
log_viewer(mode="auto")   # Opens a terminal with live output
```

## Available Tools

| Tool | Purpose |
|------|---------|
| `eval` | Evaluate Julia code with persistent state, timing, and optional timeout |
| `reset` | **Hard reset** — kills worker, spawns fresh one (enables type redefinition) |
| `info` | Get session info (version, project, typed variables, Revise status, worker ID) |
| `pkg` | Manage packages (add, rm, status, update, instantiate, resolve, test, develop, free) |
| `activate` | Switch active project/environment |
| `log_viewer` | Open a terminal window showing Julia output in real-time |
| `session` | Manage multiple sessions (create, switch, list, destroy) |
| `revise` | Hot-reload code changes (revise, track, includet, status) |

All tools accept an optional `session` parameter to target a specific session. When omitted, the current session is used.

### Eval Tool Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `code` | string | (required) | Julia code to evaluate |
| `timeout` | number | none | Max execution time in seconds. Worker is killed on timeout. |
| `max_output` | integer | 50000 | Max characters before output is truncated (head+tail preserved) |
| `max_stackframes` | integer | 5 | Max stacktrace frames in errors. Increase for deep macro errors. |
| `session` | string | current | Target session name |

Every eval result includes execution timing (e.g., `[45.2ms]` or `[1.23s]`).

## Critical: Beautiful Code and Output Display

**The goal is to make Julia work feel like an interactive REPL session.**

### Before Evaluation: Show the Code

Always display code in a readable format **before** calling `eval`. The MCP permission prompt shows code as an escaped string which is difficult to read.

```
Running this Julia code:
```julia
A = [1 2 3; 4 5 6; 7 8 9]
det(A)
```

[then call eval]
```

### After Evaluation: Format Results Beautifully

Present results in REPL-style with proper formatting:

```julia
julia> A = [1 2 3; 4 5 6; 7 8 9]
3×3 Matrix{Int64}:
 1  2  3
 4  5  6
 7  8  9

julia> det(A)
0.0
```

## Session Management

### Default Session
If you call `eval` without creating a session, a "default" session is auto-created. Single-session workflows work identically to before.

### When to Create Multiple Sessions
- **Development + Testing**: Keep compiled state separate
- **Multiple Projects**: Different environments side by side
- **Benchmarking**: Isolate benchmark state from development
- **Experimentation**: Try risky changes without affecting main work

### Session Commands
```
session(action="create", name="analysis")   # Create new session
session(action="switch", name="analysis")   # Switch to it
session(action="list")                      # See all sessions
session(action="destroy", name="old")       # Clean up
```

Each session has its own:
- Worker process (isolated state)
- Project environment
- Revise.jl tracking
- Variables and loaded packages

## Revise.jl Workflow (Maximize Session Lifespan)

**Revise.jl is the #1 tool for minimizing REPL restarts.** It's auto-loaded on every worker.

### Core Workflow
1. Edit `.jl` source files (using Edit/Write tools)
2. Call `revise(action="revise")` to hot-reload changes
3. Continue working — all session state is preserved

### When to Use Revise vs Reset

| Change Type | Revise | Reset |
|-------------|--------|-------|
| Function body | Use revise | Unnecessary |
| New function/method | Use revise | Unnecessary |
| Method signature | Use revise | Unnecessary |
| Struct **layout** (Julia < 1.12) | Won't work | Required |
| Corrupted state | Won't fix | Required |
| Clean slate needed | Not applicable | Required |

### Revise Actions
```
revise(action="revise")                          # Pick up all file changes
revise(action="track", path="src/myfile.jl")     # Track a file
revise(action="includet", path="script.jl")      # Hot-reloadable include
revise(action="status")                          # What is Revise watching?
```

### After Editing Julia Files
Whenever you edit a `.jl` file, call `revise(action="revise")` to reload the changes into the session. This is automatic if the PostToolUse hook is active.

## Understanding TTFX (Time to First X)

The first call to `eval` in a session may take several seconds due to:
- Julia's JIT compilation
- Package loading and precompilation

Subsequent calls are fast because the worker process stays alive with compiled code in memory. This is the core value proposition of AgentREPL.

## Session Persistence

Variables, functions, and loaded packages persist across `eval` calls:

```julia
# First call
x = 42
f(n) = n^2
```

```julia
# Later call — x and f still exist
f(x)  # Returns 1764
```

## Hard Reset with `reset`

The `reset` tool **kills the worker process and spawns a fresh one**. This means:
- All variables are cleared
- All loaded packages are unloaded
- **Type definitions can be changed** (necessary in Julia < 1.12)
- Revise.jl is reloaded automatically

**Prefer `revise` over `reset` whenever possible** — it preserves your session state.

After reset, packages need to be reloaded with `using`.
The activated environment persists across resets.

## Plotting & Visualization

UnicodePlots.jl renders terminal-native plots directly in eval output — no GUI needed:

```julia
using UnicodePlots
lineplot(sin, -2π, 2π, title="Sine Wave")
```

Plots appear as colored Unicode Braille art in the tool response. Supports line, scatter, bar, histogram, heatmap, density, contour, box plots, and more. Use `/julia-plot` for the full reference.

## Environment Management

Julia best practice is to use project-specific environments. Use `activate` to switch:

```
activate(path=".")              # Current directory
activate(path="/path/to/proj")  # Specific project
activate(path="@v1.10")         # Named shared environment
```

After activation, install dependencies:
```
pkg(action="instantiate")
```

The activated environment persists across `reset` calls.

## Package Management

Use `pkg` for all package operations:

**Adding packages:**
```
pkg(action="add", packages="JSON, DataFrames, CSV")
```

**Development workflow (local packages):**
```
pkg(action="develop", packages="./path/to/MyLocalPackage")
```
After developing, Revise.jl automatically tracks the package source.

After adding/developing, load the package:
```julia
using JSON
```

## Testing Workflow

For running tests, prefer `pkg(action="test")`:
- With no packages specified, tests the current project
- With packages specified, tests those specific packages

**Before running tests, call `revise(action="revise")`** to pick up latest code changes.

For faster iteration on specific test files:
```julia
include("test/runtests.jl")
```

## Development Workflow (Full Cycle)

When developing a Julia package:

1. **Activate and set up**:
   ```
   activate(path="./MyPackage")
   pkg(action="instantiate")
   ```

2. **Load the package**:
   ```julia
   using MyPackage
   ```

3. **Edit source files** — make changes to `src/*.jl`

4. **Hot-reload**:
   ```
   revise(action="revise")
   ```

5. **Test**:
   ```
   pkg(action="test")
   ```

6. **Repeat steps 3-5** — no restart needed

## Performance Analysis

### Benchmarking
```julia
using BenchmarkTools
@benchmark sort(rand(1000))
@btime myfunction($x)  # Use $ for interpolation
```

### Type Stability
```julia
@code_warntype myfunction(args...)
```
Red `Any` or `Union` types indicate type instability — fix these for performance.

### Profiling
```julia
using Profile
@profile myfunction(args...)
Profile.print(noisefloor=2.0)
```

## Debugging Without Restart

Avoid restarting the session for debugging:

- **`@show x`** — print variable with name
- **`@info "message" x y`** — structured logging
- **`@assert condition "message"`** — runtime assertions
- **`Infiltrator.@infiltrate`** — drop into sub-REPL at a point (requires `using Infiltrator`)

## Error Handling

| Error | Cause | Solution |
|-------|-------|----------|
| `UndefVarError` | Variable not defined | Re-run earlier code or check spelling |
| `MethodError` | Wrong argument types | Check function signatures |
| `LoadError` | Package not installed | Use `pkg(action="add", packages="...")` |
| `cannot redefine` | Type redefinition | Use `reset` (or `revise` for non-struct changes) |
| `StackOverflowError` | Infinite recursion | Fix recursion, may need `reset` |

## Handling Hung Code

Use the `timeout` parameter when evaluating code that might hang:

```
eval(code="while true end", timeout=5)  # kills worker after 5s
```

If code is already stuck, use `reset` to kill the worker and recover.

## First-Time Setup

When first using Julia in a session:
1. Ask the user which environment to use (current directory, specific path, or global)
2. `activate` and `pkg(action="instantiate")`
3. Check Revise.jl availability: `revise(action="status")`

## When NOT to Use These Tools

Prefer direct bash commands when:
- Running a standalone Julia script: `julia script.jl`
- Running with specific command-line flags
- The task is one-shot and doesn't benefit from persistence

Use the MCP tools when:
- Interactive development and exploration
- Iterative work where state should persist
- Avoiding TTFX overhead matters
- Package development with hot-reloading
- Working with multiple projects simultaneously
