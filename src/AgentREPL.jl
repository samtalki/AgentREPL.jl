"""
    AgentREPL

A persistent Julia REPL for AI agents via MCP (Model Context Protocol).

AgentREPL solves Julia's "Time to First X" (TTFX) problem by maintaining a persistent
worker subprocess. Instead of spawning fresh Julia processes for each command (1-2s startup),
the REPL stays alive and you only pay the startup cost once.

# Architecture

AgentREPL uses a worker subprocess model via Distributed.jl:
- The MCP server runs in the main process (STDIO transport)
- Code evaluation happens in a spawned worker process
- `reset` kills the worker and spawns a fresh one (enables type redefinition)
- `activate` switches the worker's project/environment

# Quick Start

Using the Claude Code plugin (recommended):
```bash
claude /plugin add samtalki/AgentREPL.jl
```

Or manual MCP configuration:
```bash
claude mcp add julia-repl -- julia --project=/path/to/AgentREPL.jl /path/to/AgentREPL.jl/bin/julia-repl-server
```

# Tools Provided

- `eval` - Evaluate Julia code with persistent state
- `reset` - Hard reset (kills worker, spawns fresh one, enables type redefinition)
- `info` - Get session info (Julia version, project, variables, worker ID)
- `pkg` - Manage packages (add, rm, status, update, instantiate, resolve, test, develop, free)
- `activate` - Switch active project/environment

# See Also

- [ModelContextProtocol.jl](https://github.com/JuliaSMLM/ModelContextProtocol.jl) - MCP framework
- [Modern Julia Workflows](https://modernjuliaworkflows.org/) - Best practices guide
"""
module AgentREPL

using ModelContextProtocol
using Distributed
using Pkg
using Dates

export start_server

"""
    WorkerState

Mutable state container for the worker subprocess.

# Fields
- `worker_id::Union{Int, Nothing}`: The Distributed.jl worker process ID, or `nothing` if no worker exists
- `project_path::Union{String, Nothing}`: Path to the active Julia project/environment, persists across resets
"""
mutable struct WorkerState
    worker_id::Union{Int, Nothing}
    project_path::Union{String, Nothing}
end

"""
    WORKER::WorkerState

Global state for the worker subprocess. Access via `ensure_worker!()` rather than directly.
"""
const WORKER = WorkerState(nothing, nothing)

"""
    LogViewerState

State for the optional log viewer feature that displays REPL output in a separate terminal.

# Fields
- `log_path::Union{String, Nothing}`: Path to the log file (default: `~/.julia/logs/repl.log`)
- `log_io::Union{IO, Nothing}`: Open file handle for writing logs
- `viewer_pid::Union{Int, Nothing}`: PID of the viewer process (if spawned)
- `mode::Symbol`: Current mode - `:none`, `:file`, or `:tmux`
"""
mutable struct LogViewerState
    log_path::Union{String, Nothing}
    log_io::Union{IO, Nothing}
    viewer_pid::Union{Int, Nothing}
    mode::Symbol  # :none, :file, :tmux
end

"""
    LOG_VIEWER::LogViewerState

Global state for the log viewer. Configure via `setup_log_viewer!()`.
"""
const LOG_VIEWER = LogViewerState(nothing, nothing, nothing, :none)

"""
    TmuxREPLState

State for the tmux-based bidirectional REPL mode (alternative to distributed worker model).

# Fields
- `session_name::String`: Name of the tmux session (default: `"julia-repl"`)
- `active::Bool`: Whether the tmux session is currently running
- `project_path::Union{String, Nothing}`: Path to the active Julia project
- `terminal_opened::Bool`: Whether a terminal window has been opened for this session
"""
mutable struct TmuxREPLState
    session_name::String
    active::Bool
    project_path::Union{String, Nothing}
    terminal_opened::Bool
end

"""
    TMUX_REPL::TmuxREPLState

Global state for tmux-based REPL mode. Only used when `REPL_MODE[] == :tmux`.
"""
const TMUX_REPL = TmuxREPLState("julia-repl", false, nothing, false)

"""
    REPL_MODE::Ref{Symbol}

Global REPL execution mode. Possible values:
- `:distributed` (default): Uses Distributed.jl worker subprocess
- `:tmux`: Uses tmux session for bidirectional REPL with visible terminal

Set via `JULIA_REPL_MODE` environment variable before starting the server.
"""
const REPL_MODE = Ref{Symbol}(:distributed)

"""
    find_tmux() -> Union{String, Nothing}

Find the tmux executable path.
"""
function find_tmux()
    for path in ["/usr/bin/tmux", "/usr/local/bin/tmux", "/opt/homebrew/bin/tmux"]
        if isfile(path)
            return path
        end
    end
    # Fallback: try to find via which
    try
        return strip(read(`which tmux`, String))
    catch
        return nothing
    end
end

"""
    TMUX_PATH::Ref{Union{String, Nothing}}

Cached path to the tmux executable. Populated lazily by `get_tmux_path()`.
"""
const TMUX_PATH = Ref{Union{String, Nothing}}(nothing)

"""
    get_tmux_path() -> Union{String, Nothing}

Get the cached tmux path, finding it if not yet cached.
"""
function get_tmux_path()
    if TMUX_PATH[] === nothing
        TMUX_PATH[] = find_tmux()
    end
    return TMUX_PATH[]
end

"""
    has_tmux() -> Bool

Check if tmux is available on the system.
"""
function has_tmux()
    return get_tmux_path() !== nothing
end

"""
    tmux_cmd(args...) -> Cmd

Build a tmux command using the detected tmux path.
"""
function tmux_cmd(args...)
    tmux = get_tmux_path()
    if tmux === nothing
        error("tmux not found")
    end
    return Cmd([tmux, args...])
end

"""
    ensure_tmux_repl!(; open_terminal::Bool=true) -> Bool

Ensure a tmux-based Julia REPL session exists. Creates one if needed.
Returns true if session is ready, false if tmux is not available.
"""
function ensure_tmux_repl!(; open_terminal::Bool=true)
    if !has_tmux()
        @warn "tmux is not installed. Install it with: sudo dnf install tmux"
        return false
    end

    # Check if session already exists and is running Julia
    if TMUX_REPL.active
        try
            run(pipeline(`tmux has-session -t $(TMUX_REPL.session_name)`, devnull))
            return true
        catch
            TMUX_REPL.active = false
        end
    end

    # Kill any existing session with our name
    try
        run(ignorestatus(pipeline(`tmux kill-session -t $(TMUX_REPL.session_name)`, devnull)))
    catch
    end

    # Build Julia command with project if specified
    # Use shell quoting for tmux which passes to sh -c
    julia_cmd = if TMUX_REPL.project_path !== nothing
        "julia --project='$(TMUX_REPL.project_path)'"
    else
        "julia"
    end

    # Create new tmux session with Julia REPL
    # tmux new-session runs the command through a shell, so we pass it as a single string
    try
        run(`tmux new-session -d -s $(TMUX_REPL.session_name) sh -c $julia_cmd`)
        TMUX_REPL.active = true

        # Wait for Julia to start (look for the prompt)
        for _ in 1:50  # Up to 5 seconds
            sleep(0.1)
            pane_content = read(`tmux capture-pane -t $(TMUX_REPL.session_name) -p`, String)
            if contains(pane_content, "julia>")
                break
            end
        end

        @info "Julia REPL started in tmux session '$(TMUX_REPL.session_name)'"
    catch e
        @error "Failed to create tmux session" exception=e
        return false
    end

    # Open a visible terminal window if requested
    if open_terminal && !TMUX_REPL.terminal_opened
        if open_terminal_with_tmux_attach()
            TMUX_REPL.terminal_opened = true
        end
    end

    return true
end

"""
    open_terminal_with_tmux_attach() -> Bool

Open a terminal window attached to the Julia REPL tmux session.
"""
function open_terminal_with_tmux_attach()
    terminal = find_terminal_emulator()
    if terminal === nothing
        @info "No terminal emulator found. Attach manually with: tmux attach -t $(TMUX_REPL.session_name)"
        return false
    end

    try
        session = TMUX_REPL.session_name
        if Sys.isapple()
            script = """
            tell application "Terminal"
                activate
                do script "tmux attach -t $session"
            end tell
            """
            run(pipeline(`osascript -e $script`, devnull))
        elseif terminal == "gnome-terminal"
            run(pipeline(`gnome-terminal -- tmux attach -t $session`, devnull); wait=false)
        elseif terminal == "konsole"
            run(pipeline(`konsole -e tmux attach -t $session`, devnull); wait=false)
        elseif terminal == "xfce4-terminal"
            run(pipeline(`xfce4-terminal -e "tmux attach -t $session"`, devnull); wait=false)
        elseif terminal == "kitty"
            run(pipeline(`kitty tmux attach -t $session`, devnull); wait=false)
        elseif terminal == "alacritty"
            run(pipeline(`alacritty -e tmux attach -t $session`, devnull); wait=false)
        elseif terminal == "xterm"
            run(pipeline(`xterm -e tmux attach -t $session`, devnull); wait=false)
        end
        @info "Opened terminal attached to Julia REPL (tmux session: $session)"
        return true
    catch e
        @warn "Could not open terminal" exception=e
        return false
    end
end

"""
    kill_tmux_repl!()

Kill the tmux-based Julia REPL session.
"""
function kill_tmux_repl!()
    if TMUX_REPL.active
        try
            run(ignorestatus(pipeline(`tmux kill-session -t $(TMUX_REPL.session_name)`, devnull)))
        catch
        end
        TMUX_REPL.active = false
        TMUX_REPL.terminal_opened = false
    end
end

"""
    generate_marker() -> String

Generate a unique marker for detecting command completion.
"""
function generate_marker()
    return "__DONE_$(rand(UInt64))__"
end

"""
    eval_in_tmux(code::String; timeout::Float64=30.0) -> (value_str, output, error_str)

Evaluate Julia code in the tmux REPL session.
Returns (value_str, output, error_str) similar to capture_eval_on_worker.
"""
function eval_in_tmux(code::String; timeout::Float64=30.0)
    if !ensure_tmux_repl!()
        return ("nothing", "", "Error: tmux REPL not available")
    end

    session = TMUX_REPL.session_name
    marker = generate_marker()

    # Capture pane content before sending command (to find where new output starts)
    pre_content = read(`tmux capture-pane -t $session -p -S -1000`, String)
    pre_lines = length(split(pre_content, '\n'))

    # Send the code (handle multi-line by sending each line)
    code_lines = split(strip(code), '\n')
    for line in code_lines
        # Escape any special characters for tmux
        escaped_line = replace(line, "'" => "'\\''")
        run(`tmux send-keys -t $session $escaped_line Enter`)
        sleep(0.05)  # Small delay between lines
    end

    # Send marker command to detect completion
    run(`tmux send-keys -t $session "println(\"$marker\")" Enter`)

    # Wait for marker to appear in output
    start_time = time()
    output_content = ""
    found_marker = false

    while (time() - start_time) < timeout
        sleep(0.1)
        current_content = read(`tmux capture-pane -t $session -p -S -1000`, String)

        if contains(current_content, marker)
            found_marker = true
            output_content = current_content
            break
        end
    end

    if !found_marker
        return ("nothing", "", "Error: Command timed out after $(timeout)s")
    end

    # Parse the output to extract result and printed output
    # The output format in Julia REPL is:
    # julia> <code>
    # <output/result>
    # julia> println("marker")
    # marker

    lines = split(output_content, '\n')

    # Find where our code started (after the last julia> prompt before our code)
    code_start_idx = 0
    for (i, line) in enumerate(lines)
        if startswith(strip(line), "julia>") && i > pre_lines - 10
            # Check if this prompt has our code
            rest = strip(replace(line, "julia>" => ""))
            if !isempty(rest) && startswith(strip(code_lines[1]), strip(rest)[1:min(10, length(strip(rest)))])
                code_start_idx = i
                break
            elseif isempty(rest) && i < length(lines)
                # Multi-line input starts on next line
                code_start_idx = i
                break
            end
        end
    end

    # Find marker line
    marker_idx = 0
    for (i, line) in enumerate(lines)
        if contains(line, marker)
            marker_idx = i
            break
        end
    end

    # Extract output between code and marker
    if code_start_idx > 0 && marker_idx > code_start_idx
        # Skip the code lines and the println marker command
        output_start = code_start_idx + length(code_lines)
        output_end = marker_idx - 2  # Skip "julia> println..." and marker itself

        if output_end >= output_start
            output_lines = lines[output_start:output_end]
            # Filter out empty lines and julia> prompts
            output_lines = filter(l -> !isempty(strip(l)) && !startswith(strip(l), "julia>"), output_lines)

            # The last non-empty line is typically the result
            if !isempty(output_lines)
                # Check for errors
                full_output = join(output_lines, '\n')
                if contains(full_output, "ERROR:") || contains(full_output, "LoadError") || contains(full_output, "UndefVarError")
                    return ("nothing", "", strip(full_output))
                end

                # Separate printed output from return value
                # Return value is usually the last line
                if length(output_lines) == 1
                    return (strip(output_lines[1]), "", nothing)
                else
                    result = strip(output_lines[end])
                    printed = join(output_lines[1:end-1], '\n')
                    return (result, strip(printed), nothing)
                end
            end
        end
    end

    return ("nothing", "", nothing)
end

"""
    get_default_log_path() -> String

Get the default path for the REPL log file.
"""
function get_default_log_path()
    log_dir = joinpath(homedir(), ".julia", "logs")
    mkpath(log_dir)
    return joinpath(log_dir, "repl.log")
end

"""
    setup_log_viewer!(; mode::Symbol=:auto, log_path::Union{String,Nothing}=nothing)

Set up the log viewer for the Julia REPL session.

Modes:
- `:auto` - Try tmux first, fall back to opening a terminal with tail -f
- `:tmux` - Use tmux (creates session "julia-repl")
- `:file` - Just log to file, user manually runs tail -f
- `:none` - Disable logging

Returns the log file path if logging is enabled.
"""
function setup_log_viewer!(; mode::Symbol=:auto, log_path::Union{String,Nothing}=nothing)
    # Close existing log if open
    if LOG_VIEWER.log_io !== nothing
        close(LOG_VIEWER.log_io)
        LOG_VIEWER.log_io = nothing
    end

    if mode == :none
        LOG_VIEWER.mode = :none
        LOG_VIEWER.log_path = nothing
        return nothing
    end

    # Set up log file
    path = something(log_path, get_default_log_path())
    LOG_VIEWER.log_path = path
    LOG_VIEWER.log_io = open(path, "w")

    # Write header
    println(LOG_VIEWER.log_io, "="^60)
    println(LOG_VIEWER.log_io, "Julia REPL Session - $(Dates.now())")
    println(LOG_VIEWER.log_io, "="^60)
    println(LOG_VIEWER.log_io)
    flush(LOG_VIEWER.log_io)

    if mode == :auto
        # Try tmux first, then terminal
        if try_open_tmux_viewer(path)
            LOG_VIEWER.mode = :tmux
        elseif try_open_terminal_viewer(path)
            LOG_VIEWER.mode = :file
        else
            LOG_VIEWER.mode = :file
            @warn "Could not auto-open log viewer. Run manually: tail -f $path"
        end
    elseif mode == :tmux
        if try_open_tmux_viewer(path)
            LOG_VIEWER.mode = :tmux
        else
            LOG_VIEWER.mode = :file
            @warn "tmux not available. Run manually: tail -f $path"
        end
    else  # :file
        LOG_VIEWER.mode = :file
        if !try_open_terminal_viewer(path)
            @warn "Could not auto-open terminal. Run manually: tail -f $path"
        end
    end

    return path
end

"""
    find_terminal_emulator() -> Union{String, Nothing}

Find an available terminal emulator on the system.
"""
function find_terminal_emulator()
    if Sys.islinux()
        # Try common terminal emulators in order of preference
        terminals = ["gnome-terminal", "konsole", "xfce4-terminal", "kitty", "alacritty", "xterm"]
        for term in terminals
            try
                run(pipeline(`which $term`, devnull))
                return term
            catch
            end
        end
    elseif Sys.isapple()
        return "Terminal.app"  # Always available on macOS
    end
    return nothing
end

"""
    try_open_tmux_viewer(log_path::String) -> Bool

Try to open a tmux session showing the log file in a visible terminal window.
"""
function try_open_tmux_viewer(log_path::String)
    # Check if tmux is available
    try
        run(pipeline(`which tmux`, devnull))
    catch
        return false
    end

    # Kill existing julia-repl session if any
    try
        run(ignorestatus(pipeline(`tmux kill-session -t julia-repl`, devnull)))
    catch
    end

    # Create new tmux session in detached mode
    try
        run(`tmux new-session -d -s julia-repl tail -f $log_path`)
    catch
        return false
    end

    # Now open a terminal window attached to the tmux session
    terminal = find_terminal_emulator()
    if terminal === nothing
        @info "tmux session 'julia-repl' created. Attach with: tmux attach -t julia-repl"
        return true
    end

    # Open terminal with tmux attach
    try
        if Sys.isapple()
            script = """
            tell application "Terminal"
                activate
                do script "tmux attach -t julia-repl"
            end tell
            """
            run(pipeline(`osascript -e $script`, devnull))
        elseif terminal == "gnome-terminal"
            run(pipeline(`gnome-terminal -- tmux attach -t julia-repl`, devnull); wait=false)
        elseif terminal == "konsole"
            run(pipeline(`konsole -e tmux attach -t julia-repl`, devnull); wait=false)
        elseif terminal == "xfce4-terminal"
            run(pipeline(`xfce4-terminal -e "tmux attach -t julia-repl"`, devnull); wait=false)
        elseif terminal == "kitty"
            run(pipeline(`kitty tmux attach -t julia-repl`, devnull); wait=false)
        elseif terminal == "alacritty"
            run(pipeline(`alacritty -e tmux attach -t julia-repl`, devnull); wait=false)
        elseif terminal == "xterm"
            run(pipeline(`xterm -e tmux attach -t julia-repl`, devnull); wait=false)
        end
        @info "Opened Julia REPL viewer in $terminal (tmux session: julia-repl)"
        return true
    catch e
        @warn "Could not open terminal window" terminal exception=e
        @info "tmux session 'julia-repl' created. Attach manually with: tmux attach -t julia-repl"
        return true  # tmux session exists, just couldn't open terminal
    end
end

"""
    try_open_terminal_viewer(log_path::String) -> Bool

Try to open a terminal emulator showing tail -f of the log file (no tmux).
"""
function try_open_terminal_viewer(log_path::String)
    terminal = find_terminal_emulator()
    if terminal === nothing
        return false
    end

    try
        if Sys.isapple()
            script = """
            tell application "Terminal"
                activate
                do script "tail -f '$log_path'"
            end tell
            """
            run(pipeline(`osascript -e $script`, devnull))
        elseif terminal == "gnome-terminal"
            run(pipeline(`gnome-terminal -- tail -f $log_path`, devnull); wait=false)
        elseif terminal == "konsole"
            run(pipeline(`konsole -e tail -f $log_path`, devnull); wait=false)
        elseif terminal == "xfce4-terminal"
            run(pipeline(`xfce4-terminal -e "tail -f $log_path"`, devnull); wait=false)
        elseif terminal == "kitty"
            run(pipeline(`kitty tail -f $log_path`, devnull); wait=false)
        elseif terminal == "alacritty"
            run(pipeline(`alacritty -e tail -f $log_path`, devnull); wait=false)
        elseif terminal == "xterm"
            run(pipeline(`xterm -e tail -f $log_path`, devnull); wait=false)
        end
        @info "Opened Julia REPL viewer in $terminal"
        return true
    catch e
        @warn "Could not open terminal window" terminal exception=e
        return false
    end
end

"""
    log_interaction(code::String, value_str::String, output::String, error_str::Union{String,Nothing})

Log an interaction to the log file if logging is enabled.
"""
function log_interaction(code::String, value_str::String, output::String, error_str::Union{String,Nothing})
    LOG_VIEWER.log_io === nothing && return

    io = LOG_VIEWER.log_io
    println(io, "─"^60)
    println(io, "julia> ", replace(strip(code), "\n" => "\n       "))
    println(io)

    if error_str !== nothing
        println(io, "ERROR: ", error_str)
    else
        if !isempty(strip(output))
            println(io, strip(output))
        end
        println(io, value_str)
    end
    println(io)
    flush(io)
end

"""
    close_log_viewer!()

Close the log viewer and clean up.
"""
function close_log_viewer!()
    if LOG_VIEWER.log_io !== nothing
        println(LOG_VIEWER.log_io, "\n", "="^60)
        println(LOG_VIEWER.log_io, "Session ended - $(Dates.now())")
        println(LOG_VIEWER.log_io, "="^60)
        close(LOG_VIEWER.log_io)
        LOG_VIEWER.log_io = nothing
    end

    # Kill tmux session if we created one
    if LOG_VIEWER.mode == :tmux
        try
            run(ignorestatus(pipeline(`tmux kill-session -t julia-repl`, devnull)))
        catch
        end
    end

    LOG_VIEWER.mode = :none
end

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
            catch repr_err
                try
                    string(value)
                catch str_err
                    # Final fallback for types that can't be stringified (e.g., JSON3.Object)
                    "<$(typeof(value))>"
                end
            end

            (value_str, combined_output, error_str)
        end
    end

    return remotecall_fetch(Core.eval, worker_id, Main, eval_expr)
end

"""
    truncate_stacktrace(error_str::String; max_frames::Int=5) -> String

Truncate a stacktrace to the most relevant frames.
Keeps the error message and first few frames, adds note if truncated.
"""
function truncate_stacktrace(error_str::String; max_frames::Int=5)
    lines = split(error_str, '\n')

    # Find where stacktrace starts (after "Stacktrace:")
    stacktrace_idx = findfirst(l -> startswith(strip(l), "Stacktrace:"), lines)

    if stacktrace_idx === nothing
        return error_str  # No stacktrace, return as-is
    end

    # Keep error message and "Stacktrace:" line
    result_lines = lines[1:stacktrace_idx]

    # Count frames (lines starting with [N])
    remaining_lines = lines[stacktrace_idx+1:end]
    frame_count = 0
    last_included_idx = 0

    for (i, line) in enumerate(remaining_lines)
        if occursin(r"^\s*\[\d+\]", line)
            frame_count += 1
            if frame_count <= max_frames
                last_included_idx = i
            end
        elseif frame_count <= max_frames
            last_included_idx = i
        end
    end

    if frame_count > max_frames
        append!(result_lines, remaining_lines[1:last_included_idx])
        push!(result_lines, "  ... ($(frame_count - max_frames) more frames truncated)")
    else
        append!(result_lines, remaining_lines)
    end

    return join(result_lines, '\n')
end

"""
    format_result(value_str::String, output::String, error_str::Union{String,Nothing}) -> String

Format the evaluation result for display to the user.
Compact plain-text format (markdown isn't rendered in MCP tool output).
Code is NOT included since the caller shows it before the tool call.
"""
function format_result(value_str::String, output::String, error_str::Union{String,Nothing})
    result_parts = String[]

    if error_str !== nothing
        truncated_error = truncate_stacktrace(error_str)
        push!(result_parts, truncated_error)
    else
        push!(result_parts, "→ $value_str")
    end

    # Include printed output inline for compactness (visible in collapsed view)
    if !isempty(strip(output))
        output_lines = split(strip(output), '\n')
        if length(output_lines) == 1
            # Single line: inline with label
            push!(result_parts, "Output: $(output_lines[1])")
        else
            # Multiple lines: first line inline, rest below
            push!(result_parts, "Output: $(output_lines[1])")
            for line in output_lines[2:end]
                push!(result_parts, line)
            end
        end
    end

    return join(result_parts, "\n")
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

Supports:
- Regular paths: "/path/to/project", "./relative/path"
- Current directory: "." or "@."
- Shared environments: "@v1.12", "@myenv" (expands to ~/.julia/environments/...)
"""
function activate_project_on_worker!(path::String)
    worker_id = ensure_worker!()

    # Handle shared environment syntax (@v1.12, @myenv, etc.)
    # The @ prefix syntax only works in Pkg REPL mode, not programmatically
    resolved_path = if startswith(path, "@") && path != "@."
        env_name = path[2:end]  # Strip the @ prefix
        joinpath(homedir(), ".julia", "environments", env_name)
    else
        path
    end

    activate_expr = quote
        let p = $resolved_path
            try
                Pkg.activate(p)
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
                elseif act == "test"
                    if isempty(pkgs)
                        Pkg.test()
                    else
                        Pkg.test(pkgs)
                    end
                elseif act == "develop"
                    # develop can take paths or package names
                    for pkg in pkgs
                        if startswith(pkg, "/") || startswith(pkg, ".") || startswith(pkg, "~")
                            Pkg.develop(path=expanduser(pkg))
                        else
                            Pkg.develop(pkg)
                        end
                    end
                elseif act == "free"
                    Pkg.free(pkgs)
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

Start the AgentREPL MCP server using STDIO transport.

# Arguments
- `project_dir`: Optional path to a Julia project to activate on the worker.

# Tools Provided
- `eval`: Evaluate Julia code with persistent state
- `reset`: Hard reset (kills worker, spawns fresh one, enables type redefinition)
- `info`: Get session information (version, project, variables, worker ID)
- `pkg`: Manage packages (add, rm, status, update, instantiate, resolve, test, develop, free)
- `activate`: Switch active project/environment

# Example
```julia
using AgentREPL
AgentREPL.start_server()  # Blocks, waiting for MCP client
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

    # Check for REPL mode environment variable
    # JULIA_REPL_MODE: "distributed" (default) or "tmux" (bidirectional with visible terminal)
    repl_mode_str = get(ENV, "JULIA_REPL_MODE", "distributed")
    REPL_MODE[] = Symbol(repl_mode_str)

    if REPL_MODE[] == :tmux
        # Set project path for tmux REPL
        TMUX_REPL.project_path = project_dir
        @info "Using tmux-based bidirectional REPL mode"
    else
        # Check for log viewer environment variables (only for distributed mode)
        # JULIA_REPL_VIEWER: "auto", "tmux", "file", "none" (default: "none")
        # JULIA_REPL_LOG: path to log file (default: ~/.julia/logs/repl.log)
        viewer_mode_str = get(ENV, "JULIA_REPL_VIEWER", "none")
        viewer_mode = Symbol(viewer_mode_str)
        log_path = get(ENV, "JULIA_REPL_LOG", nothing)

        if viewer_mode != :none
            setup_log_viewer!(; mode=viewer_mode, log_path=log_path)
        end
    end

    # NOTE: Worker/tmux session is spawned lazily on first tool use to avoid
    # conflicts with MCP STDIO transport during startup

    # Tool: Evaluate Julia code
    eval_tool = MCPTool(
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

            result = format_result(value_str, output, error_str)
            TextContent(text = result)
        end
    )

    # Tool: Hard reset (kill and respawn worker/session)
    reset_tool = MCPTool(
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

    # Tool: Session info
    info_tool = MCPTool(
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

    # Tool: Package management
    pkg_tool = MCPTool(
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

    # Tool: Activate project/environment
    activate_tool = MCPTool(
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

    # Tool: Log viewer control
    log_viewer_tool = MCPTool(
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

    # Create and start the server
    server = mcp_server(
        name = "julia-repl",
        version = "0.3.0",
        description = "Persistent Julia REPL for AI agents - eliminates TTFX",
        tools = [eval_tool, reset_tool, info_tool, pkg_tool, activate_tool, log_viewer_tool]
    )

    @info "AgentREPL server starting..." julia_version=VERSION
    start!(server)
end

end # module
