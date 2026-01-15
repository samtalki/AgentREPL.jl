"""
    AgentEval

A Julia package that provides persistent code evaluation for AI agents via MCP STDIO transport.

Unlike HTTP-based alternatives (MCPRepl.jl), AgentEval uses STDIO transport which:
- Opens no network ports (more secure)
- Auto-spawns when MCP client needs it (no manual startup)
- Can be registered in Julia General registry

# Quick Start

```julia
using AgentEval
AgentEval.start_server()  # Blocks, waiting for MCP client
```

# Claude Code Configuration

```bash
claude mcp add julia-eval -- julia --project=/path/to/AgentEval.jl -e "using AgentEval; AgentEval.start_server()"
```

# Tools Provided

- `julia_eval` - Evaluate Julia code with persistent state
- `julia_reset` - Soft reset (clear variables, cannot redefine types)
- `julia_info` - Get session info (Julia version, loaded packages, variables)

# See Also

- [ModelContextProtocol.jl](https://github.com/JuliaSMLM/ModelContextProtocol.jl) - MCP framework
- [MCPRepl.jl](https://github.com/hexaeder/MCPRepl.jl) - HTTP-based alternative
"""
module AgentEval

using ModelContextProtocol
using Pkg

export start_server

# Symbols to exclude from reset (Julia internals)
const PROTECTED_SYMBOLS = Set([
    :Base, :Core, :Main, :ans, :include, :eval,
    :AgentEval, :ModelContextProtocol, :Pkg
])

"""
    capture_eval(code::String) -> (value, output, error, backtrace)

Evaluate Julia code and capture both the return value and any printed output.
Returns a tuple of (value, stdout_output, error_or_nothing, backtrace_or_nothing).
"""
function capture_eval(code::String)
    value = nothing
    err = nothing
    bt = nothing

    old_stdout = stdout
    old_stderr = stderr

    rd_out, wr_out = redirect_stdout()
    rd_err, wr_err = redirect_stderr()

    try
        # Evaluate in Main module so definitions persist
        value = include_string(Main, code, "AgentEval[REPL]")
    catch e
        err = e
        bt = catch_backtrace()
    finally
        # Restore stdout/stderr
        redirect_stdout(old_stdout)
        redirect_stderr(old_stderr)
        close(wr_out)
        close(wr_err)
    end

    # Read captured output, ensuring pipes are closed even on read failure
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

    return (value, combined_output, err, bt)
end

"""
    format_result(value, output::String, err, bt=nothing) -> String

Format the evaluation result for display to the user.
"""
function format_result(value, output::String, err, bt=nothing)
    if err !== nothing
        error_msg = if bt !== nothing
            sprint(showerror, err, bt)
        else
            sprint(showerror, err)
        end
        return "Error:\n$error_msg"
    end

    result_parts = String[]

    if !isempty(strip(output))
        push!(result_parts, "Output:\n$output")
    end

    # Format the return value
    value_str = try
        repr(value)
    catch
        string(value)
    end
    push!(result_parts, "Result: $value_str")

    return join(result_parts, "\n\n")
end

"""
    get_user_symbols() -> Vector{Symbol}

Get all user-defined symbols in Main module (excluding Julia internals).
"""
function get_user_symbols()
    all_names = names(Main; all=true)
    user_symbols = Symbol[]

    for name in all_names
        name_str = string(name)
        # Skip internal symbols (start with # or _)
        if startswith(name_str, "#") || startswith(name_str, "_")
            continue
        end
        # Skip protected symbols
        if name in PROTECTED_SYMBOLS
            continue
        end
        push!(user_symbols, name)
    end

    return user_symbols
end

"""
    start_server(; project_dir::Union{String,Nothing}=nothing)

Start the AgentEval MCP server using STDIO transport.

# Arguments
- `project_dir`: Optional path to a Julia project to activate before starting.

# Tools Provided
- `julia_eval`: Evaluate Julia code with persistent state
- `julia_reset`: Soft reset (clear variables, cannot redefine types)
- `julia_info`: Get session information

# Example
```julia
using AgentEval
AgentEval.start_server()  # Blocks, waiting for MCP client
```
"""
function start_server(; project_dir::Union{String,Nothing}=nothing)
    # Activate project if specified
    if project_dir !== nothing
        if !isdir(project_dir)
            error("Cannot activate project: directory '$project_dir' not found")
        end

        try
            Pkg.activate(project_dir)
            @info "Activated project" project_dir
        catch e
            error("Cannot activate project at '$project_dir': $(sprint(showerror, e))")
        end
    end

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

            # Validate input
            if code === nothing || !isa(code, AbstractString)
                return TextContent(text = "Error: 'code' parameter is required and must be a string")
            end

            if isempty(strip(code))
                return TextContent(text = "Error: 'code' parameter cannot be empty")
            end

            value, output, err, bt = capture_eval(code)
            result = format_result(value, output, err, bt)
            TextContent(text = result)
        end
    )

    # Tool: Soft reset
    reset_tool = MCPTool(
        name = "julia_reset",
        description = """
Soft reset: Clear user-defined variables in the Main module.

Note: This cannot redefine types or structs. If you need to redefine
a type, the user must restart their Claude Code session (which will
spawn a fresh Julia process).

Use this when you want to start fresh without restarting Julia.
""",
        parameters = [],
        handler = _ -> begin
            cleared = String[]
            skipped = String[]
            for name in Base.invokelatest(get_user_symbols)
                try
                    Core.eval(Main, :($(name) = nothing))
                    push!(cleared, string(name))
                catch e
                    # Expected: const bindings and special variables can't be reassigned
                    if e isa ErrorException && occursin("cannot assign", e.msg)
                        push!(skipped, string(name))
                    else
                        # Unexpected error - include details
                        push!(skipped, "$(name) ($(typeof(e).name.name))")
                    end
                end
            end

            msg = if isempty(cleared) && isempty(skipped)
                "No user variables to clear."
            elseif isempty(cleared)
                "No variables cleared. Skipped $(length(skipped)) const/protected: $(join(skipped, ", "))"
            else
                result = "Cleared $(length(cleared)) variable(s): $(join(cleared, ", "))"
                if !isempty(skipped)
                    result *= "\nSkipped $(length(skipped)) const/protected: $(join(skipped, ", "))"
                end
                result *= "\n\nNote: Type redefinitions require restarting the Claude session."
                result
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
- Number of loaded packages
""",
        parameters = [],
        handler = _ -> begin
            user_vars = Base.invokelatest(get_user_symbols)
            project_path = try
                dirname(Pkg.project().path)
            catch
                "(no project)"
            end

            loaded_pkgs = try
                length(keys(Base.loaded_modules))
            catch
                0
            end

            info = """
Julia Version: $(VERSION)
Active Project: $project_path
User Variables: $(isempty(user_vars) ? "(none)" : join(user_vars, ", "))
Loaded Modules: $loaded_pkgs
"""
            TextContent(text = info)
        end
    )

    # Create and start the server
    server = mcp_server(
        name = "agent-eval",
        version = "0.1.0",
        description = "Persistent Julia code evaluation for AI agents - eliminates TTFX",
        tools = [eval_tool, reset_tool, info_tool]
    )

    @info "AgentEval server starting..." julia_version=VERSION
    start!(server)
end

end # module
