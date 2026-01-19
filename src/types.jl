# types.jl - State structs and global constants

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
- `:tmux`: Uses tmux session for bidirectional REPL with visible terminal (DEPRECATED)

Set via `JULIA_REPL_MODE` environment variable before starting the server.
"""
const REPL_MODE = Ref{Symbol}(:distributed)

"""
    HighlightConfig

Configuration for Julia syntax highlighting.

# Fields
- `enabled::Bool`: Whether syntax highlighting is enabled (default: true)
- `format::Symbol`: Output format - `:ansi`, `:markdown`, or `:plain` (default: :ansi)
"""
mutable struct HighlightConfig
    enabled::Bool
    format::Symbol
end

"""
    _validate_output_format(format_str::String) -> Symbol

Validate and return the output format symbol. Returns `:ansi` if invalid.
"""
function _validate_output_format(format_str::String)::Symbol
    format_sym = Symbol(lowercase(format_str))
    valid_formats = Set([:ansi, :markdown, :plain])
    if format_sym ∉ valid_formats
        @warn "Invalid JULIA_REPL_OUTPUT_FORMAT='$format_str', using default 'ansi'. Valid options: ansi, markdown, plain"
        return :ansi
    end
    return format_sym
end

"""
    HIGHLIGHT_CONFIG::HighlightConfig

Global syntax highlighting configuration. Set via environment variables:
- `JULIA_REPL_HIGHLIGHT`: "true" or "false" (default: "true")
- `JULIA_REPL_OUTPUT_FORMAT`: "ansi", "markdown", or "plain" (default: "ansi")
"""
const HIGHLIGHT_CONFIG = HighlightConfig(
    lowercase(get(ENV, "JULIA_REPL_HIGHLIGHT", "true")) == "true",
    _validate_output_format(get(ENV, "JULIA_REPL_OUTPUT_FORMAT", "ansi"))
)
