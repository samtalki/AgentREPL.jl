# deprecated/tmux.jl - Deprecated tmux bidirectional REPL functionality

"""
    DEPRECATED: Tmux Bidirectional REPL Mode

This module contains the deprecated tmux bidirectional REPL functionality.
The tmux mode has unfixable issues with marker pollution in the terminal output.

To enable (NOT RECOMMENDED):
    Set JULIA_REPL_ENABLE_TMUX=true environment variable

Recommended alternative:
    Use distributed mode (default) with log viewer for visual output:
    - Set JULIA_REPL_VIEWER=auto
    - Or manually: tail -f ~/.julia/logs/repl.log
"""

"""
    TMUX_ENABLED::Ref{Bool}

Whether tmux mode is enabled. Disabled by default.
Set JULIA_REPL_ENABLE_TMUX=true to enable (not recommended).
"""
const TMUX_ENABLED = Ref(get(ENV, "JULIA_REPL_ENABLE_TMUX", "false") == "true")

"""
    TMUX_DEPRECATION_WARNED::Ref{Bool}

Track whether we've already warned about tmux deprecation this session.
"""
const TMUX_DEPRECATION_WARNED = Ref(false)

"""
    warn_tmux_deprecated()

Emit a warning about tmux mode deprecation (once per session).
"""
function warn_tmux_deprecated()
    if !TMUX_DEPRECATION_WARNED[]
        @warn """
        Tmux REPL mode is deprecated and will be removed in a future version.

        The tmux mode has unfixable issues with marker pollution in the terminal.
        Use distributed mode (default) with log viewer for visual output:
        - Set JULIA_REPL_VIEWER=auto for visual output
        - Or manually: tail -f ~/.julia/logs/repl.log
        """
        TMUX_DEPRECATION_WARNED[] = true
    end
end

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

DEPRECATED: Use distributed mode with log viewer instead.
"""
function ensure_tmux_repl!(; open_terminal::Bool=true)
    warn_tmux_deprecated()

    if !has_tmux()
        @warn "tmux is not installed. Install it with: sudo dnf install tmux"
        return false
    end

    # Check if session already exists (whether we think it's active or not)
    session_exists = try
        run(pipeline(`tmux has-session -t $(TMUX_REPL.session_name)`, devnull))
        true
    catch
        false
    end

    # If session exists and has Julia running, reconnect to it
    if session_exists
        # Verify Julia is running by checking for the julia> prompt
        pane_content = try
            read(`tmux capture-pane -t $(TMUX_REPL.session_name) -p`, String)
        catch
            ""
        end

        if contains(pane_content, "julia>")
            TMUX_REPL.active = true
            @info "Reconnected to existing Julia REPL in tmux session '$(TMUX_REPL.session_name)'"
            # Still try to open terminal if requested (user may have closed it)
            if open_terminal && !TMUX_REPL.terminal_opened
                if open_terminal_with_tmux_attach()
                    TMUX_REPL.terminal_opened = true
                end
            end
            return true
        end
    end

    # Kill any existing session with our name (it's stale or not running Julia)
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

DEPRECATED: Has unfixable marker pollution issues. Use distributed mode instead.
"""
function eval_in_tmux(code::String; timeout::Float64=30.0)
    warn_tmux_deprecated()

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
    # NOTE: This marker is visible in the terminal - this is an unfixable architectural issue
    run(`tmux send-keys -t $session $("println(\"$marker\")") Enter`)

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
        output_end = marker_idx - 2  # Skip "julia> println..." and marker line

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
