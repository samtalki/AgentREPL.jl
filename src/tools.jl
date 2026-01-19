# tools.jl - MCP tool definitions

"""
    create_eval_tool() -> MCPTool

Create the eval tool for evaluating Julia code.
"""
function create_eval_tool()
    MCPTool(
        name = "eval",
        description = """
Evaluate Julia code in a persistent Julia REPL session.

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

            # Use appropriate backend based on mode
            if REPL_MODE[] == :tmux
                value_str, output, error_str = eval_in_tmux(code)
            else
                value_str, output, error_str = capture_eval_on_worker(code)
                log_interaction(code, value_str, output, error_str)
            end

            result = format_result(code, value_str, output, error_str)
            TextContent(text = result)
        end
    )
end

"""
    create_reset_tool() -> MCPTool

Create the reset tool for resetting the Julia session.
"""
function create_reset_tool()
    MCPTool(
        name = "reset",
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
            if REPL_MODE[] == :tmux
                kill_tmux_repl!()
                ensure_tmux_repl!()

                msg = """
Session reset complete (tmux mode).
- Julia REPL session restarted
- All variables, functions, and types cleared
- Packages will need to be reloaded with `using`
"""
                if TMUX_REPL.project_path !== nothing
                    msg *= "- Project: $(TMUX_REPL.project_path)\n"
                end
                TextContent(text = msg)
            else
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
        end
    )
end

"""
    create_info_tool() -> MCPTool

Create the info tool for getting session information.
"""
function create_info_tool()
    MCPTool(
        name = "info",
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
end

"""
    create_pkg_tool() -> MCPTool

Create the pkg tool for package management.
"""
function create_pkg_tool()
    MCPTool(
        name = "pkg",
        description = """
Manage Julia packages in the current environment.

Actions:
- add: Install packages (e.g., packages="JSON, DataFrames")
- rm: Remove packages
- status: Show installed packages
- update: Update packages (all if packages not specified)
- instantiate: Download and precompile dependencies from Project.toml/Manifest.toml
- resolve: Resolve dependency graph and update Manifest.toml
- test: Run package tests (current project if no packages specified)
- develop: Put packages in development mode (use local code instead of registry)
- free: Exit development mode (return to using registry version)

The packages parameter accepts space or comma-separated names.
For 'develop', you can use paths (starting with /, ., or ~) or package names.

Examples:
- pkg(action="add", packages="JSON, DataFrames")
- pkg(action="status")
- pkg(action="test")
- pkg(action="develop", packages="./MyLocalPackage")
- pkg(action="free", packages="MyPackage")
""",
        parameters = [
            ToolParameter(
                name = "action",
                type = "string",
                description = "Package action: add, rm, status, update, instantiate, resolve, test, develop, or free",
                required = true
            ),
            ToolParameter(
                name = "packages",
                type = "string",
                description = "Space or comma-separated package names or paths. Required for add, rm, develop, free. Optional for update, test.",
                required = false
            )
        ],
        handler = params -> begin
            action = get(params, "action", nothing)
            if action === nothing || !isa(action, AbstractString)
                return TextContent(text = "Error: 'action' parameter is required and must be a string")
            end

            action_lower = lowercase(strip(action))
            valid_actions = ["add", "rm", "status", "update", "instantiate", "resolve", "test", "develop", "free"]
            if action_lower ∉ valid_actions
                return TextContent(text = "Error: action must be one of: $(join(valid_actions, ", ")) (got: '$action')")
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

            # Actions that require packages
            if action_lower in ["add", "rm", "develop", "free"] && isempty(pkg_list)
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
            elseif action_lower == "test"
                isempty(pkg_list) ? "Ran tests for current project" : "Ran tests for: $(join(pkg_list, ", "))"
            elseif action_lower == "develop"
                "Put $(length(pkg_list)) package(s) in development mode: $(join(pkg_list, ", "))"
            elseif action_lower == "free"
                "Freed $(length(pkg_list)) package(s) from development mode: $(join(pkg_list, ", "))"
            else
                "Completed action: $action_lower"
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
end

"""
    create_activate_tool() -> MCPTool

Create the activate tool for switching projects/environments.
"""
function create_activate_tool()
    MCPTool(
        name = "activate",
        description = """
Activate a Julia project or environment.

Supports:
- Path to a project directory containing Project.toml
- "." or "@." to activate the current directory
- Named environments like "@v1.10" for shared environments

Examples:
- activate(path=".")  # Current directory
- activate(path="/path/to/MyProject")
- activate(path="@v1.10")  # Shared environment

After activation, use `pkg(action="instantiate")` to install dependencies.
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
                TextContent(text = "Activated project: $(result.project)\n\nUse `pkg(action=\"instantiate\")` to install dependencies if needed.")
            else
                TextContent(text = "Error activating project: $(result.error)")
            end
        end
    )
end

"""
    create_log_viewer_tool() -> MCPTool

Create the log_viewer tool for controlling the log viewer.
"""
function create_log_viewer_tool()
    MCPTool(
        name = "log_viewer",
        description = """
Open a separate terminal window showing Julia REPL output in real-time.

This opens a log viewer so you can see Julia output outside of the MCP response.
Modes:
- "auto": Try tmux first, then open a terminal with tail -f
- "tmux": Create a tmux session (attach with: tmux attach -t julia-repl)
- "file": Just enable logging, user opens tail -f manually
- "off": Disable the log viewer

The log file is written to ~/.julia/logs/repl.log by default.
""",
        parameters = [
            ToolParameter(
                name = "mode",
                type = "string",
                description = "Viewer mode: 'auto', 'tmux', 'file', or 'off'",
                required = true
            )
        ],
        handler = params -> begin
            mode_str = get(params, "mode", "auto")
            if mode_str == "off"
                close_log_viewer!()
                return TextContent(text = "Log viewer disabled.")
            end

            mode = Symbol(mode_str)
            if mode ∉ [:auto, :tmux, :file]
                return TextContent(text = "Error: mode must be 'auto', 'tmux', 'file', or 'off'")
            end

            path = setup_log_viewer!(; mode=mode)

            if LOG_VIEWER.mode == :tmux
                TextContent(text = "Log viewer enabled (tmux).\nLog file: $path\nAttach with: tmux attach -t julia-repl")
            elseif LOG_VIEWER.mode == :file
                TextContent(text = "Log viewer enabled.\nLog file: $path\nA terminal window should have opened. If not, run: tail -f $path")
            else
                TextContent(text = "Log viewer enabled.\nLog file: $path\nRun in another terminal: tail -f $path")
            end
        end
    )
end

"""
    create_mode_tool() -> MCPTool

Create the mode tool for switching REPL modes.
"""
function create_mode_tool()
    MCPTool(
        name = "mode",
        description = """
Switch between distributed worker and tmux REPL modes at runtime.

Modes:
- "distributed": Uses Distributed.jl worker subprocess (default, headless)
- "tmux": Uses tmux session with visible terminal for bidirectional REPL

Both modes can coexist - switching does not clean up the inactive mode.
When switching to tmux, a terminal window will auto-open if not already visible.

Use `mode(mode="tmux")` to see Julia output in a live terminal that you can also type in directly.
""",
        parameters = [
            ToolParameter(
                name = "mode",
                type = "string",
                description = "REPL mode: 'distributed' or 'tmux'",
                required = true
            )
        ],
        handler = params -> begin
            mode_str = get(params, "mode", nothing)
            if mode_str === nothing || !isa(mode_str, AbstractString)
                return TextContent(text = "Error: 'mode' parameter is required and must be a string")
            end

            mode_sym = Symbol(lowercase(strip(mode_str)))
            if mode_sym ∉ [:distributed, :tmux]
                return TextContent(text = "Error: mode must be 'distributed' or 'tmux' (got: '$mode_str')")
            end

            # Check if already in requested mode
            if REPL_MODE[] == mode_sym
                return TextContent(text = "Already in $mode_sym mode.")
            end

            # Handle tmux mode with deprecation check
            if mode_sym == :tmux
                if !TMUX_ENABLED[]
                    return TextContent(text = """
Error: Tmux mode is deprecated and disabled by default.

Tmux mode has unfixable issues with marker pollution in the terminal.
Use distributed mode with log viewer instead:
- Set JULIA_REPL_VIEWER=auto for visual output
- Or manually: tail -f ~/.julia/logs/repl.log

To force-enable tmux (not recommended):
Set JULIA_REPL_ENABLE_TMUX=true environment variable.
""")
                end

                if !ensure_tmux_repl!(; open_terminal=true)
                    return TextContent(text = "Error: tmux mode unavailable (tmux not installed). Install with: sudo dnf install tmux")
                end
                # Success - now update the mode
                REPL_MODE[] = mode_sym
                worker_info = WORKER.worker_id !== nothing ? "Worker (ID: $(WORKER.worker_id)) remains available" : "No distributed worker active"
                msg = """
Mode switched to: tmux
- Julia REPL running in tmux session '$(TMUX_REPL.session_name)'
- Terminal window should be visible (you can type directly in it)
- $worker_info
"""
            else  # :distributed
                try
                    ensure_worker!()
                catch e
                    return TextContent(text = "Error: Failed to start distributed worker: $e")
                end
                # Success - now update the mode
                REPL_MODE[] = mode_sym
                tmux_info = TMUX_REPL.active ? "Tmux session '$(TMUX_REPL.session_name)' remains running" : "No tmux session active"
                msg = """
Mode switched to: distributed
- Using Distributed.jl worker (ID: $(WORKER.worker_id))
- $tmux_info
"""
            end

            TextContent(text = msg)
        end
    )
end
