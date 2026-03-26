# tools.jl - MCP tool definitions

"""
    _validate_action(params, valid_actions::Vector{String}) -> String

Validate and extract an action parameter. Returns the lowercased action string.
Throws `ArgumentError` if validation fails.
"""
function _validate_action(params, valid_actions::Vector{String})
    action = get(params, "action", nothing)
    if action === nothing || !isa(action, AbstractString)
        throw(ArgumentError("'action' parameter is required and must be a string"))
    end
    action_lower = lowercase(strip(action))
    if action_lower ∉ valid_actions
        throw(ArgumentError("action must be one of: $(join(valid_actions, ", ")) (got: '$action')"))
    end
    return action_lower
end

"""
    _require_string_param(params, name::String, action::String) -> String

Extract and validate a required string parameter. Returns the stripped string.
Throws `ArgumentError` if the parameter is missing or not a string.
"""
function _require_string_param(params, name::String, action::String)
    val = get(params, name, nothing)
    if val === nothing || !isa(val, AbstractString)
        throw(ArgumentError("'$name' parameter is required for action '$action'"))
    end
    return String(strip(val))
end

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
- Execution time is shown for every evaluation

Use this for iterative development, testing, and exploration.
Use `revise(action="revise")` after editing .jl files to hot-reload changes without losing session state.
""",
        parameters = [
            ToolParameter(
                name = "code",
                type = "string",
                description = "Julia code to evaluate. Can be single expressions or multi-line code blocks.",
                required = true
            ),
            ToolParameter(
                name = "timeout",
                type = "number",
                description = "Maximum execution time in seconds. If exceeded, the worker is killed and respawns on next eval. Use for potentially long-running or infinite code.",
                required = false
            ),
            ToolParameter(
                name = "max_output",
                type = "integer",
                description = "Maximum characters for output/value before truncation (default: 50000). Prevents context window overflow from large outputs.",
                required = false
            ),
            ToolParameter(
                name = "max_stackframes",
                type = "integer",
                description = "Maximum stacktrace frames to show in errors (default: 5). Increase for deep macro errors, decrease for simple errors.",
                required = false
            ),
            ToolParameter(
                name = "session",
                type = "string",
                description = "Session name to evaluate in. If omitted, uses the current session.",
                required = false
            ),
            ToolParameter(
                name = "isolated",
                type = "boolean",
                description = "If true, evaluate in a fresh anonymous module instead of Main. Variables and functions won't persist — useful for one-shot computations or experimental code that shouldn't pollute the session namespace.",
                required = false
            ),
            ToolParameter(
                name = "ephemeral",
                type = "boolean",
                description = "If true, evaluate in a temporary session that is automatically destroyed after execution. Provides full process isolation — separate worker, clean state, no side effects on existing sessions. More expensive than 'isolated' (spawns a new worker).",
                required = false
            )
        ],
        handler = params -> begin
            try
                code = get(params, "code", nothing)

                if code === nothing || !isa(code, AbstractString)
                    return TextContent(text = "Error: 'code' parameter is required and must be a string")
                end

                if isempty(strip(code))
                    return TextContent(text = "Error: 'code' parameter cannot be empty")
                end

                # Extract optional parameters with validation
                timeout_val = get(params, "timeout", nothing)
                timeout = try
                    timeout_val === nothing ? nothing : Float64(timeout_val)
                catch
                    return TextContent(text = "Error: 'timeout' must be a number (got: $(repr(timeout_val)))")
                end
                if timeout !== nothing && timeout <= 0
                    return TextContent(text = "Error: 'timeout' must be a positive number (got: $(repr(timeout_val)))")
                end
                max_output = try
                    Int(get(params, "max_output", 50_000))
                catch
                    return TextContent(text = "Error: 'max_output' must be an integer")
                end
                max_stackframes = try
                    Int(get(params, "max_stackframes", 5))
                catch
                    return TextContent(text = "Error: 'max_stackframes' must be an integer")
                end
                session_name = get(params, "session", nothing)
                isolated = get(params, "isolated", false) == true
                ephemeral = get(params, "ephemeral", false) == true

                # Ephemeral mode: create a temporary session, eval, then destroy it
                ephemeral_name = nothing
                if ephemeral
                    ephemeral_name = "ephemeral-$(string(rand(UInt64), base=16))"
                    create_session!(ephemeral_name)
                    session_name = ephemeral_name
                end

                try
                    value_str, output, error_str, elapsed = capture_eval_on_worker(code; timeout=timeout, session_name=session_name, isolated=isolated)
                    resolved_name = resolve_session(session_name).name
                    log_interaction(code, value_str, output, error_str; elapsed=elapsed, session_name=resolved_name)

                    result = format_result(code, value_str, output, error_str;
                                            elapsed=elapsed, max_output=max_output, max_stackframes=max_stackframes)
                    TextContent(text = result)
                finally
                    if ephemeral_name !== nothing
                        try
                            destroy_session!(ephemeral_name)
                        catch e
                            e isa InterruptException && rethrow()
                            @warn "Failed to clean up ephemeral session" name=ephemeral_name exception=e
                        end
                    end
                end
            catch e
                e isa InterruptException && rethrow()
                e isa OutOfMemoryError && rethrow()
                TextContent(text = "Internal error in eval tool: $(sprint(showerror, e))\n\nTry reset() to recover.")
            end
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
- Revise.jl is reloaded automatically

Use this when you need to redefine struct layouts (Julia < 1.12) or need a clean slate.
Prefer `revise(action="revise")` for function/method changes — it preserves session state.
""",
        parameters = [
            ToolParameter(
                name = "session",
                type = "string",
                description = "Session name to reset. If omitted, resets the current session.",
                required = false
            )
        ],
        handler = params -> begin
            try
                session_name = get(params, "session", nothing)
                session = resolve_session(session_name)

                old_id = session.worker_id
                new_id = reset_worker!(session)

                msg = """
Session reset complete.
- Old worker (ID: $old_id) terminated
- New worker (ID: $new_id) spawned
- All variables, functions, and types cleared
- Packages will need to be reloaded with `using`
- Revise.jl: $(session.revise_loaded ? "loaded" : "not available")
"""
                if session.project_path !== nothing
                    msg *= "- Project re-activated: $(session.project_path)\n"
                end

                TextContent(text = msg)
            catch e
                e isa InterruptException && rethrow()
                e isa OutOfMemoryError && rethrow()
                TextContent(text = "Internal error in reset tool: $(sprint(showerror, e))")
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
- Session name and Revise.jl status
""",
        parameters = [
            ToolParameter(
                name = "session",
                type = "string",
                description = "Session name to query. If omitted, uses the current session.",
                required = false
            )
        ],
        handler = params -> begin
            try
                session_name = get(params, "session", nothing)
                session = resolve_session(session_name)
                info = get_worker_info(session)

                vars_str = if isempty(info.variables)
                    "(none)"
                else
                    lines = String[]
                    for v in info.variables
                        entry = "  $(v.name)::$(v.type)"
                        if !isempty(v.size)
                            entry *= " $(v.size)"
                        end
                        push!(lines, entry)
                    end
                    join(lines, "\n")
                end

                timings_str = if isempty(session.eval_timings)
                    ""
                else
                    n = length(session.eval_timings)
                    sorted = sort(session.eval_timings)
                    mid = div(n, 2)
                    med = isodd(n) ? sorted[mid + 1] : (sorted[mid] + sorted[mid + 1]) / 2
                    mx = sorted[end]
                    spark = sparkline(session.eval_timings)
                    "Eval Timings ($n evals): $spark  median $(format_elapsed(med)), max $(format_elapsed(mx))\n"
                end

                msg = """
Session: $(session.name)$(session.name == SESSIONS.current ? " (current)" : "")
Julia Version: $(info.version)
Active Project: $(info.project)
Revise.jl: $(session.revise_loaded ? "loaded" : "not available")
User Variables:
$vars_str
Loaded Modules: $(info.modules)
Worker ID: $(session.worker_id)
$(timings_str)"""
                TextContent(text = msg)
            catch e
                e isa InterruptException && rethrow()
                e isa OutOfMemoryError && rethrow()
                TextContent(text = "Internal error in info tool: $(sprint(showerror, e))\n\nTry reset() to recover.")
            end
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
            ),
            ToolParameter(
                name = "session",
                type = "string",
                description = "Session name. If omitted, uses the current session.",
                required = false
            )
        ],
        handler = params -> begin
            try
                action_lower = _validate_action(params, ["add", "rm", "status", "update", "instantiate", "resolve", "test", "develop", "free"])

                packages_str = get(params, "packages", nothing)
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

                session_name = get(params, "session", nothing)
                result = run_pkg_action_on_worker(action_lower, pkg_list; session_name=session_name)

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
            catch e
                e isa InterruptException && rethrow()
                e isa OutOfMemoryError && rethrow()
                if e isa ArgumentError
                    TextContent(text = "Error: $(e.msg)")
                else
                    TextContent(text = "Internal error in pkg tool: $(sprint(showerror, e))\n\nTry reset() to recover.")
                end
            end
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
            ),
            ToolParameter(
                name = "session",
                type = "string",
                description = "Session name. If omitted, uses the current session.",
                required = false
            )
        ],
        handler = params -> begin
            try
                path = get(params, "path", nothing)
                if path === nothing || !isa(path, AbstractString)
                    return TextContent(text = "Error: 'path' parameter is required and must be a string")
                end

                session_name = get(params, "session", nothing)
                result = activate_project_on_worker!(path; session_name=session_name)

                if result.success
                    TextContent(text = "Activated project: $(result.project)\n\nUse `pkg(action=\"instantiate\")` to install dependencies if needed.")
                else
                    TextContent(text = "Error activating project: $(result.error)")
                end
            catch e
                e isa InterruptException && rethrow()
                e isa OutOfMemoryError && rethrow()
                TextContent(text = "Internal error in activate tool: $(sprint(showerror, e))\n\nTry reset() to recover.")
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
                description = "Viewer mode: 'auto' (default), 'tmux', 'file', or 'off'",
                required = false
            )
        ],
        handler = params -> begin
            try
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
            catch e
                e isa InterruptException && rethrow()
                e isa OutOfMemoryError && rethrow()
                TextContent(text = "Internal error in log_viewer tool: $(sprint(showerror, e))")
            end
        end
    )
end

"""
    create_session_tool() -> MCPTool

Create the session tool for managing multiple Julia REPL sessions.
"""
function create_session_tool()
    MCPTool(
        name = "session",
        description = """
Manage multiple Julia REPL sessions.

Each session has its own worker process with isolated state (variables, packages, project).
Use multiple sessions for parallel workflows (e.g., one for development, one for testing).

Actions:
- create: Create a new named session (worker spawns lazily on first eval)
- switch: Switch the active session
- list: Show all sessions with status
- destroy: Kill a session's worker and remove it
- attach: Open an interactive REPL in tmux that shares state with this MCP session.
  The human and agent share the same Main namespace — variables defined by either side are visible to both.
  Requires tmux. The session continues running after the human disconnects.

Examples:
- session(action="create", name="analysis")
- session(action="switch", name="analysis")
- session(action="list")
- session(action="destroy", name="analysis")
- session(action="attach") or session(action="attach", name="analysis")
""",
        parameters = [
            ToolParameter(
                name = "action",
                type = "string",
                description = "Session action: create, switch, list, destroy, or attach",
                required = true
            ),
            ToolParameter(
                name = "name",
                type = "string",
                description = "Session name. Required for create, switch, destroy. Not used for list.",
                required = false
            )
        ],
        handler = params -> begin
            try
                action_lower = _validate_action(params, ["create", "switch", "list", "destroy", "attach"])

                if action_lower in ["create", "switch", "destroy"]
                    name = _require_string_param(params, "name", action_lower)
                end

                if action_lower == "create"
                    session = create_session!(name)
                    TextContent(text = "Session '$(session.name)' created and set as current.\nWorker will spawn on first eval.")

                elseif action_lower == "switch"
                    session = switch_session!(name)
                    msg = "Switched to session '$(session.name)'.\n"
                    msg *= "Worker ID: $(something(session.worker_id, "not yet spawned"))\n"
                    msg *= "Project: $(something(session.project_path, "default"))\n"
                    msg *= "Revise.jl: $(session.revise_loaded ? "loaded" : "not loaded")"
                    TextContent(text = msg)

                elseif action_lower == "list"
                    sessions = list_sessions()
                    if isempty(sessions)
                        return TextContent(text = "No sessions. Create one with session(action=\"create\", name=\"myname\") or just call eval (auto-creates 'default').")
                    end

                    lines = String["Sessions:"]
                    for s in sessions
                        marker = s.is_current ? " *" : "  "
                        worker = s.worker_id === nothing ? "not spawned" : "worker $(s.worker_id)"
                        project = s.project === nothing ? "default env" : s.project
                        revise = s.revise ? "Revise" : "no Revise"
                        age_min = round(s.age_seconds / 60; digits=1)
                        push!(lines, "$marker $(s.name) — $worker, $project, $revise ($(age_min)min)")
                    end
                    TextContent(text = join(lines, "\n"))

                elseif action_lower == "destroy"
                    destroy_session!(name)
                    current = SESSIONS.current
                    msg = "Session '$(name)' destroyed."
                    if current !== nothing
                        msg *= "\nCurrent session: $current"
                    end
                    TextContent(text = msg)

                elseif action_lower == "attach"
                    # Attach uses optional name — defaults to current session
                    target_name = get(params, "name", nothing)
                    session = resolve_session(target_name isa AbstractString ? String(strip(target_name)) : nothing)

                    # Ensure worker is running (attach needs a live worker)
                    ensure_worker!(session)

                    # Start socket server if not already running
                    if session.socket_path === nothing || !ispath(session.socket_path)
                        _start_repl_socket_server!(session)
                    end

                    # Open tmux with the REPL client
                    tmux_name = _open_attach_tmux(session)

                    msg = "Interactive REPL opened for session '$(session.name)'.\n"
                    msg *= "tmux session: $tmux_name\n"
                    msg *= "Attach with: tmux attach -t $tmux_name\n\n"
                    msg *= "You and the agent now share the same Julia state.\n"
                    msg *= "Variables defined in either the interactive REPL or via MCP eval are visible to both."
                    TextContent(text = msg)

                else
                    error("Unexpected action: $action_lower")
                end
            catch e
                e isa InterruptException && rethrow()
                e isa OutOfMemoryError && rethrow()
                if e isa ArgumentError
                    TextContent(text = "Error: $(e.msg)")
                else
                    TextContent(text = "Internal error in session tool: $(sprint(showerror, e))")
                end
            end
        end
    )
end

"""
    create_revise_tool() -> MCPTool

Create the revise tool for hot-reloading Julia code changes.
"""
function create_revise_tool()
    MCPTool(
        name = "revise",
        description = """
Hot-reload Julia code changes using Revise.jl — no session restart needed.

Revise.jl automatically picks up changes to functions, methods, and module code
without losing session state. This is the preferred alternative to `reset`.

Actions:
- revise: Trigger Revise.revise() to pick up all file changes
- track: Start tracking a file with Revise (changes auto-detected)
- includet: Include a file with Revise tracking (hot-reloadable include)
- status: Show what Revise is currently tracking

Use `revise(action="revise")` after editing .jl files to reload changes.
Use `reset` only for struct layout changes (Julia < 1.12) or corrupted state.

Examples:
- revise(action="revise")
- revise(action="track", path="src/myfile.jl")
- revise(action="includet", path="scripts/analysis.jl")
- revise(action="status")
""",
        parameters = [
            ToolParameter(
                name = "action",
                type = "string",
                description = "Revise action: revise, track, includet, or status",
                required = true
            ),
            ToolParameter(
                name = "path",
                type = "string",
                description = "File path. Required for track and includet actions.",
                required = false
            ),
            ToolParameter(
                name = "session",
                type = "string",
                description = "Session name. If omitted, uses the current session.",
                required = false
            )
        ],
        handler = params -> begin
            try
                action_lower = _validate_action(params, ["revise", "track", "includet", "status"])

                session_name = get(params, "session", nothing)
                session = resolve_session(session_name)

                # Validate path upfront for actions that need it
                if action_lower in ["track", "includet"]
                    path = _require_string_param(params, "path", action_lower)
                end

                if action_lower == "revise"
                    ensure_worker!(session)
                    result = revise_on_worker!(session)
                    msg = result.success ? result.message : "Error: $(result.message)"
                    TextContent(text = msg)

                elseif action_lower == "track"
                    ensure_worker!(session)
                    result = track_file_on_worker!(session, path)
                    msg = result.success ? result.message : "Error: $(result.message)"
                    TextContent(text = msg)

                elseif action_lower == "includet"
                    ensure_worker!(session)
                    result = includet_on_worker!(session, path)
                    msg = result.success ? result.message : "Error: $(result.message)"
                    TextContent(text = msg)

                elseif action_lower == "status"
                    status = get_revise_status(session)
                    if !status.available
                        msg = "Revise.jl is not available in session '$(session.name)'.\nInstall it with: pkg(action=\"add\", packages=\"Revise\")"
                        if !isempty(status.note)
                            msg *= "\nNote: $(status.note)"
                        end
                        return TextContent(text = msg)
                    end

                    lines = String["Revise.jl Status (session: $(session.name)):"]
                    push!(lines, "Watched packages: $(isempty(status.watched_packages) ? "(none)" : join(status.watched_packages, ", "))")
                    push!(lines, "Tracked files: $(isempty(status.tracked_files) ? "(none)" : string(length(status.tracked_files), " files"))")
                    for f in status.tracked_files
                        push!(lines, "  - $f")
                    end
                    if !isempty(status.note)
                        push!(lines, "Note: $(status.note)")
                    end
                    TextContent(text = join(lines, "\n"))

                else
                    error("Unexpected action: $action_lower")
                end
            catch e
                e isa InterruptException && rethrow()
                e isa OutOfMemoryError && rethrow()
                if e isa ArgumentError
                    TextContent(text = "Error: $(e.msg)")
                else
                    TextContent(text = "Internal error in revise tool: $(sprint(showerror, e))\n\nTry reset() to recover.")
                end
            end
        end
    )
end
