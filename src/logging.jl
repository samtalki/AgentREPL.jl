# logging.jl - Log viewer functionality

# ANSI color codes for syntax highlighting
const ANSI_RESET = "\e[0m"
const ANSI_BOLD = "\e[1m"
const ANSI_GREEN = "\e[32m"
const ANSI_RED = "\e[31m"
const ANSI_CYAN = "\e[36m"
const ANSI_YELLOW = "\e[33m"
const ANSI_MAGENTA = "\e[35m"
const ANSI_DIM = "\e[2m"

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
Uses `less +F` for scrollable output (Ctrl+C to scroll, Shift+F to resume following).
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

    # Create new tmux session with less +F (scrollable, follows new output)
    # -R enables ANSI color interpretation
    try
        run(`tmux new-session -d -s julia-repl less -R +F $log_path`)
    catch
        return false
    end

    # Now open a terminal window attached to the tmux session
    terminal = find_terminal_emulator()
    if terminal === nothing
        @info "tmux session 'julia-repl' created. Attach with: tmux attach -t julia-repl"
        @info "Scroll: Ctrl+C to pause, arrows/PgUp/PgDn to scroll, Shift+F to resume"
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
        @info "Scroll: Ctrl+C to pause, arrows/PgUp/PgDn to scroll, Shift+F to resume"
        return true
    catch e
        @warn "Could not open terminal window" terminal exception=e
        @info "tmux session 'julia-repl' created. Attach manually with: tmux attach -t julia-repl"
        return true  # tmux session exists, just couldn't open terminal
    end
end

"""
    try_open_terminal_viewer(log_path::String) -> Bool

Try to open a terminal emulator showing log file with `less +F` (scrollable).
"""
function try_open_terminal_viewer(log_path::String)
    terminal = find_terminal_emulator()
    if terminal === nothing
        return false
    end

    # Use less +F for scrollable output with ANSI color support
    # Ctrl+C to pause and scroll, Shift+F to resume following
    less_cmd = "less -R +F '$log_path'"

    try
        if Sys.isapple()
            script = """
            tell application "Terminal"
                activate
                do script "$less_cmd"
            end tell
            """
            run(pipeline(`osascript -e $script`, devnull))
        elseif terminal == "gnome-terminal"
            run(pipeline(`gnome-terminal -- sh -c $less_cmd`, devnull); wait=false)
        elseif terminal == "konsole"
            run(pipeline(`konsole -e sh -c $less_cmd`, devnull); wait=false)
        elseif terminal == "xfce4-terminal"
            run(pipeline(`xfce4-terminal -e $less_cmd`, devnull); wait=false)
        elseif terminal == "kitty"
            run(pipeline(`kitty sh -c $less_cmd`, devnull); wait=false)
        elseif terminal == "alacritty"
            run(pipeline(`alacritty -e sh -c $less_cmd`, devnull); wait=false)
        elseif terminal == "xterm"
            run(pipeline(`xterm -e sh -c $less_cmd`, devnull); wait=false)
        end
        @info "Opened Julia REPL viewer in $terminal"
        @info "Scroll: Ctrl+C to pause, arrows/PgUp/PgDn to scroll, Shift+F to resume"
        return true
    catch e
        @warn "Could not open terminal window" terminal exception=e
        return false
    end
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

    # Write header with color
    println(LOG_VIEWER.log_io, ANSI_GREEN, "="^60, ANSI_RESET)
    println(LOG_VIEWER.log_io, ANSI_GREEN, ANSI_BOLD, "Julia REPL Session", ANSI_RESET, " - ", Dates.now())
    println(LOG_VIEWER.log_io, ANSI_DIM, "Scroll: Ctrl+C to pause, arrows to scroll, Shift+F to resume", ANSI_RESET)
    println(LOG_VIEWER.log_io, ANSI_GREEN, "="^60, ANSI_RESET)
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
    log_interaction(code::String, value_str::String, output::String, error_str::Union{String,Nothing})

Log an interaction to the log file with ANSI syntax highlighting.
Uses JuliaSyntaxHighlighting for code coloring when highlighting is enabled.
"""
function log_interaction(code::String, value_str::String, output::String, error_str::Union{String,Nothing})
    LOG_VIEWER.log_io === nothing && return

    io = LOG_VIEWER.log_io

    # Dim separator line
    println(io, ANSI_DIM, "─"^60, ANSI_RESET)

    # Apply syntax highlighting to code (force ANSI for terminal)
    highlighted_code = highlight_code(code; format=:ansi)

    # Format with continuation lines for multiline code
    code_lines = split(strip(highlighted_code), '\n')
    println(io, ANSI_GREEN, ANSI_BOLD, "julia> ", ANSI_RESET, code_lines[1])
    for line in code_lines[2:end]
        println(io, "       ", line)
    end
    println(io)

    if error_str !== nothing
        # Red error output
        println(io, ANSI_RED, ANSI_BOLD, "ERROR: ", ANSI_RESET, ANSI_RED, error_str, ANSI_RESET)
    else
        if !isempty(strip(output))
            # Cyan for printed output
            println(io, ANSI_CYAN, strip(output), ANSI_RESET)
        end
        # Normal color for result
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
