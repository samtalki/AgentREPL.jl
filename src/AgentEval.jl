"""
    AgentEval

A Julia package that provides persistent code evaluation for AI agents via MCP STDIO transport.

Unlike HTTP-based alternatives (MCPRepl.jl), AgentEval uses STDIO transport which:
- Opens no network ports (more secure)
- Auto-spawns when MCP client needs it (no manual startup)
- Can be registered in Julia General registry

# Architecture

AgentEval uses a worker subprocess model:
- The MCP server runs in the main process
- Code evaluation happens in a spawned worker process (via Distributed.jl)
- `julia_reset` kills the worker and spawns a fresh one (true reset)
- `julia_activate` switches the worker's active project/environment

# Quick Start

```julia
using AgentEval
AgentEval.start_server()  # Blocks, waiting for MCP client
```

# Claude Code Configuration

```bash
claude mcp add julia-eval -- julia --project=/path/to/AgentEval.jl /path/to/AgentEval.jl/bin/julia-eval-server
```

# Tools Provided

- `julia_eval` - Evaluate Julia code with persistent state
- `julia_reset` - Hard reset (kills worker, spawns fresh one)
- `julia_info` - Get session info (Julia version, loaded packages, variables)
- `julia_pkg` - Manage packages (add, rm, status, update, instantiate, resolve)
- `julia_activate` - Switch active project/environment

# See Also

- [ModelContextProtocol.jl](https://github.com/JuliaSMLM/ModelContextProtocol.jl) - MCP framework
- [MCPRepl.jl](https://github.com/hexaeder/MCPRepl.jl) - HTTP-based alternative
"""
module AgentEval

using ModelContextProtocol
using Distributed
using Pkg

export start_server

# Worker management
mutable struct WorkerState
    worker_id::Union{Int, Nothing}
    project_path::Union{String, Nothing}
end

const WORKER = WorkerState(nothing, nothing)

"""
    ensure_worker!() -> Int

Ensure a worker process exists, creating one if needed. Returns the worker ID.
"""
function ensure_worker!()
    if WORKER.worker_id === nothing || !(WORKER.worker_id in workers())
        # Get the current project directory so worker inherits the environment
        project_dir = dirname(Pkg.project().path)

        # Spawn a new worker with the same project environment
        new_workers = addprocs(1; exeflags=`--project=$project_dir`)
        WORKER.worker_id = first(new_workers)

        # Load Pkg on the worker using Core.eval to avoid closure serialization issues
        remotecall_fetch(Core.eval, WORKER.worker_id, Main, :(using Pkg))

        # Activate project if one was set
        if WORKER.project_path !== nothing
            try
                path = WORKER.project_path
                remotecall_fetch(Core.eval, WORKER.worker_id, Main, :(Pkg.activate($path)))
            catch e
                @warn "Failed to activate project on worker" project=WORKER.project_path error=e
            end
        end
    end
    return WORKER.worker_id
end

"""
    kill_worker!()

Kill the current worker process if one exists.
"""
function kill_worker!()
    if WORKER.worker_id !== nothing && WORKER.worker_id in workers()
        rmprocs(WORKER.worker_id)
    end
    WORKER.worker_id = nothing
end

"""
    reset_worker!()

Kill the current worker and spawn a fresh one. Returns the new worker ID.
"""
function reset_worker!()
    kill_worker!()
    return ensure_worker!()
end

"""
    capture_eval_on_worker(code::String) -> (value_str, output, error_str)

Evaluate Julia code on the worker process, capturing both return value and printed output.
Uses Core.eval with expressions to avoid closure serialization issues.
"""
function capture_eval_on_worker(code::String)
    worker_id = ensure_worker!()

    # Define the evaluation function on the worker if not already defined
    # This avoids closure serialization issues by sending code as data
    eval_expr = quote
        let code_str = $code
            value = nothing
            err = nothing
            bt = nothing

            old_stdout = stdout
            old_stderr = stderr

            rd_out, wr_out = redirect_stdout()
            rd_err, wr_err = redirect_stderr()

            try
                value = include_string(Main, code_str, "julia_eval")
            catch e
                err = e
                bt = catch_backtrace()
            finally
                redirect_stdout(old_stdout)
                redirect_stderr(old_stderr)
                close(wr_out)
                close(wr_err)
            end

            stdout_content = ""
            stderr_content = ""
            try
                stdout_content = String(read(rd_out))
                stderr_content = String(read(rd_err))
            finally
                close(rd_out)
                close(rd_err)
            end

            combined_output = stdout_content
            if !isempty(stderr_content)
                combined_output *= "\n[stderr]\n" * stderr_content
            end

            error_str = err === nothing ? nothing : sprint(showerror, err, bt)
            value_str = try
                repr(value)
            catch
                string(value)
            end

            (value_str, combined_output, error_str)
        end
    end

    return remotecall_fetch(Core.eval, worker_id, Main, eval_expr)
end

"""
    format_result(code::String, value_str::String, output::String, error_str::Union{String,Nothing}) -> String

Format the evaluation result for display to the user.
Shows result first for better visibility in collapsed view, then output, then code.
"""
function format_result(code::String, value_str::String, output::String, error_str::Union{String,Nothing})
    result_parts = String[]

    # Show error or result FIRST for visibility in collapsed output
    if error_str !== nothing
        push!(result_parts, "Error: $error_str")
    else
        push!(result_parts, "Result: $value_str")
    end

    # Include printed output (may exist even if there's an error)
    if !isempty(strip(output))
        push!(result_parts, "Output:\n$output")
    end

    # Show code last (user already saw it before approving)
    push!(result_parts, "Code:\n```julia\n$(strip(code))\n```")

    return join(result_parts, "\n\n")
end

"""
    get_worker_info() -> NamedTuple

Get information about the current worker session.
"""
function get_worker_info()
    worker_id = ensure_worker!()

    info_expr = quote
        # Get user-defined symbols
        all_names = names(Main; all=true)
        protected = Set([:Base, :Core, :Main, :ans, :include, :eval, :Pkg])
        user_vars = Symbol[]
        for name in all_names
            name_str = string(name)
            if !startswith(name_str, "#") && !startswith(name_str, "_") && !(name in protected)
                push!(user_vars, name)
            end
        end

        # Get project path
        project_path = try
            dirname(Pkg.project().path)
        catch
            "(no project)"
        end

        # Get loaded modules count
        loaded_count = try
            length(keys(Base.loaded_modules))
        catch
            0
        end

        (
            version = string(VERSION),
            project = project_path,
            variables = user_vars,
            modules = loaded_count
        )
    end

    return remotecall_fetch(Core.eval, worker_id, Main, info_expr)
end

"""
    activate_project_on_worker!(path::String)

Activate a Julia project/environment on the worker.
"""
function activate_project_on_worker!(path::String)
    worker_id = ensure_worker!()

    activate_expr = quote
        let p = $path
            try
                if p == "@." || p == "."
                    Pkg.activate(".")
                elseif startswith(p, "@")
                    Pkg.activate(p)
                else
                    Pkg.activate(p)
                end
                (success = true, project = dirname(Pkg.project().path))
            catch e
                (success = false, error = sprint(showerror, e))
            end
        end
    end

    result = remotecall_fetch(Core.eval, worker_id, Main, activate_expr)

    if result.success
        WORKER.project_path = result.project
    end

    return result
end

"""
    run_pkg_action_on_worker(action::String, pkg_list::Vector{String})

Run a Pkg action on the worker process.
"""
function run_pkg_action_on_worker(action::String, pkg_list::Vector{String})
    worker_id = ensure_worker!()

    pkg_expr = quote
        let act = $action, pkgs = $pkg_list
            old_stdout = stdout
            old_stderr = stderr
            rd_out, wr_out = redirect_stdout()
            rd_err, wr_err = redirect_stderr()

            err = nothing
            try
                if act == "add"
                    Pkg.add(pkgs)
                elseif act == "rm"
                    Pkg.rm(pkgs)
                elseif act == "status"
                    Pkg.status()
                elseif act == "update"
                    if isempty(pkgs)
                        Pkg.update()
                    else
                        Pkg.update(pkgs)
                    end
                elseif act == "instantiate"
                    Pkg.instantiate()
                elseif act == "resolve"
                    Pkg.resolve()
                end
            catch e
                err = sprint(showerror, e, catch_backtrace())
            finally
                redirect_stdout(old_stdout)
                redirect_stderr(old_stderr)
                close(wr_out)
                close(wr_err)
            end

            stdout_content = ""
            stderr_content = ""
            try
                stdout_content = String(read(rd_out))
                stderr_content = String(read(rd_err))
            finally
                close(rd_out)
                close(rd_err)
            end

            (error = err, stdout = stdout_content, stderr = stderr_content)
        end
    end

    return remotecall_fetch(Core.eval, worker_id, Main, pkg_expr)
end

"""
    start_server(; project_dir::Union{String,Nothing}=nothing)

Start the AgentEval MCP server using STDIO transport.

# Arguments
- `project_dir`: Optional path to a Julia project to activate on the worker.

# Tools Provided
- `julia_eval`: Evaluate Julia code with persistent state
- `julia_reset`: Hard reset (kills worker, spawns fresh one)
- `julia_info`: Get session information
- `julia_pkg`: Manage packages
- `julia_activate`: Switch active project/environment

# Example
```julia
using AgentEval
AgentEval.start_server()  # Blocks, waiting for MCP client
```
"""
function start_server(; project_dir::Union{String,Nothing}=nothing)
    # Set initial project path (worker will be spawned lazily on first use)
    if project_dir !== nothing
        if !isdir(project_dir)
            error("Cannot activate project: directory '$project_dir' not found")
        end
        WORKER.project_path = project_dir
    end

    # NOTE: Worker is spawned lazily on first tool use to avoid
    # conflicts with MCP STDIO transport during startup

    # Tool: Evaluate Julia code
    eval_tool = MCPTool(
        name = "julia_eval",
        description = """
Evaluate Julia code in a persistent Julia session.

Features:
- Variables and functions persist across calls
- Packages loaded once stay loaded (no TTFX penalty)
- Both return value and printed output are captured
- Errors are caught and reported with backtraces

Use this for iterative development, testing, and exploration.
""",
        parameters = [
            ToolParameter(
                name = "code",
                type = "string",
                description = "Julia code to evaluate. Can be single expressions or multi-line code blocks.",
                required = true
            )
        ],
        handler = params -> begin
            code = get(params, "code", nothing)

            if code === nothing || !isa(code, AbstractString)
                return TextContent(text = "Error: 'code' parameter is required and must be a string")
            end

            if isempty(strip(code))
                return TextContent(text = "Error: 'code' parameter cannot be empty")
            end

            value_str, output, error_str = capture_eval_on_worker(code)
            result = format_result(code, value_str, output, error_str)
            TextContent(text = result)
        end
    )

    # Tool: Hard reset (kill and respawn worker)
    reset_tool = MCPTool(
        name = "julia_reset",
        description = """
Hard reset: Kill the Julia worker process and spawn a fresh one.

This provides a true reset:
- All variables are cleared
- All loaded packages are unloaded
- Type definitions are cleared (unlike soft reset)
- The worker starts completely fresh

Use this when you need a clean slate or to redefine types/structs.
""",
        parameters = [],
        handler = _ -> begin
            old_id = WORKER.worker_id
            new_id = reset_worker!()

            msg = """
Session reset complete.
- Old worker (ID: $old_id) terminated
- New worker (ID: $new_id) spawned
- All variables, functions, and types cleared
- Packages will need to be reloaded with `using`
"""
            if WORKER.project_path !== nothing
                msg *= "- Project re-activated: $(WORKER.project_path)\n"
            end

            TextContent(text = msg)
        end
    )

    # Tool: Session info
    info_tool = MCPTool(
        name = "julia_info",
        description = """
Get information about the current Julia session.

Returns:
- Julia version
- Active project path
- List of user-defined variables
- Number of loaded modules
- Worker process ID
""",
        parameters = [],
        handler = _ -> begin
            info = get_worker_info()

            vars_str = isempty(info.variables) ? "(none)" : join(info.variables, ", ")

            msg = """
Julia Version: $(info.version)
Active Project: $(info.project)
User Variables: $vars_str
Loaded Modules: $(info.modules)
Worker ID: $(WORKER.worker_id)
"""
            TextContent(text = msg)
        end
    )

    # Tool: Package management
    pkg_tool = MCPTool(
        name = "julia_pkg",
        description = """
Manage Julia packages in the current environment.

Actions:
- add: Install packages (e.g., packages="JSON, DataFrames")
- rm: Remove packages
- status: Show installed packages
- update: Update packages (all if packages not specified)
- instantiate: Download and precompile all dependencies from Project.toml/Manifest.toml
- resolve: Resolve dependency graph and update Manifest.toml

The packages parameter accepts space or comma-separated names.

Examples:
- julia_pkg(action="add", packages="JSON")
- julia_pkg(action="add", packages="JSON, DataFrames, CSV")
- julia_pkg(action="rm", packages="OldPackage")
- julia_pkg(action="status")
- julia_pkg(action="update")
- julia_pkg(action="instantiate")
- julia_pkg(action="resolve")
""",
        parameters = [
            ToolParameter(
                name = "action",
                type = "string",
                description = "Package action: 'add', 'rm', 'status', 'update', 'instantiate', or 'resolve'",
                required = true
            ),
            ToolParameter(
                name = "packages",
                type = "string",
                description = "Space or comma-separated package names. Required for 'add' and 'rm', optional for 'update'.",
                required = false
            )
        ],
        handler = params -> begin
            action = get(params, "action", nothing)
            if action === nothing || !isa(action, AbstractString)
                return TextContent(text = "Error: 'action' parameter is required and must be a string")
            end

            action_lower = lowercase(strip(action))
            if action_lower ∉ ["add", "rm", "status", "update", "instantiate", "resolve"]
                return TextContent(text = "Error: action must be one of: add, rm, status, update, instantiate, resolve (got: '$action')")
            end

            packages_str = get(params, "packages", "")
            if packages_str === nothing
                packages_str = ""
            end

            pkg_list = String[]
            if !isempty(strip(packages_str))
                for part in split(packages_str, r"[,\s]+")
                    cleaned = strip(part)
                    if !isempty(cleaned)
                        push!(pkg_list, cleaned)
                    end
                end
            end

            if action_lower in ["add", "rm"] && isempty(pkg_list)
                return TextContent(text = "Error: 'packages' parameter is required for action '$action_lower'")
            end

            result = run_pkg_action_on_worker(action_lower, pkg_list)

            if result.error !== nothing
                return TextContent(text = "Error during Pkg.$action_lower:\n$(result.error)")
            end

            action_summary = if action_lower == "add"
                "Added $(length(pkg_list)) package(s): $(join(pkg_list, ", "))"
            elseif action_lower == "rm"
                "Removed $(length(pkg_list)) package(s): $(join(pkg_list, ", "))"
            elseif action_lower == "status"
                "Package Status:"
            elseif action_lower == "update"
                isempty(pkg_list) ? "Updated all packages" : "Updated $(length(pkg_list)) package(s): $(join(pkg_list, ", "))"
            elseif action_lower == "instantiate"
                "Instantiated environment (downloaded and precompiled dependencies)"
            elseif action_lower == "resolve"
                "Resolved dependencies (updated Manifest.toml)"
            end

            result_parts = [action_summary]
            if !isempty(strip(result.stdout))
                push!(result_parts, "\nOutput:\n$(result.stdout)")
            end
            if !isempty(strip(result.stderr))
                push!(result_parts, "\n[stderr]\n$(result.stderr)")
            end

            TextContent(text = join(result_parts, ""))
        end
    )

    # Tool: Activate project/environment
    activate_tool = MCPTool(
        name = "julia_activate",
        description = """
Activate a Julia project or environment.

Supports:
- Path to a project directory containing Project.toml
- "." or "@." to activate the current directory
- Named environments like "@v1.10" for shared environments

Examples:
- julia_activate(path=".")  # Current directory
- julia_activate(path="/path/to/MyProject")
- julia_activate(path="@v1.10")  # Shared environment

After activation, use `julia_pkg(action="instantiate")` to install dependencies.
""",
        parameters = [
            ToolParameter(
                name = "path",
                type = "string",
                description = "Path to project directory, '.' for current directory, or named environment like '@v1.10'",
                required = true
            )
        ],
        handler = params -> begin
            path = get(params, "path", nothing)
            if path === nothing || !isa(path, AbstractString)
                return TextContent(text = "Error: 'path' parameter is required and must be a string")
            end

            result = activate_project_on_worker!(path)

            if result.success
                TextContent(text = "Activated project: $(result.project)\n\nUse `julia_pkg(action=\"instantiate\")` to install dependencies if needed.")
            else
                TextContent(text = "Error activating project: $(result.error)")
            end
        end
    )

    # Create and start the server
    server = mcp_server(
        name = "agent-eval",
        version = "0.2.0",
        description = "Persistent Julia code evaluation for AI agents - eliminates TTFX",
        tools = [eval_tool, reset_tool, info_tool, pkg_tool, activate_tool]
    )

    @info "AgentEval server starting..." julia_version=VERSION
    start!(server)
end

end # module
