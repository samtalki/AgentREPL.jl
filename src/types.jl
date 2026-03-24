# types.jl - State structs and global constants

"""
    SessionState

State for a named Julia REPL session. Each session has its own worker process,
project environment, and Revise.jl tracking state.

# Fields
- `name::String`: Session name (e.g., "default", "analysis", "testing") — must not be empty, immutable after construction
- `worker_id::Union{Int, Nothing}`: Distributed.jl worker process ID
- `project_path::Union{String, Nothing}`: Active project/environment path (persists across resets)
- `revise_loaded::Bool`: Whether Revise.jl was successfully loaded on the worker
- `created_at::Float64`: Session creation time (from `time()`)
- `last_used::Float64`: Last time this session was used (from `time()`)
"""
mutable struct SessionState
    const name::String
    worker_id::Union{Int, Nothing}
    project_path::Union{String, Nothing}
    revise_loaded::Bool
    created_at::Float64
    last_used::Float64

    function SessionState(name::String, worker_id::Union{Int,Nothing}, project_path::Union{String,Nothing}, revise_loaded::Bool=false)
        isempty(name) && error("Session name must not be empty")
        now = time()
        new(name, worker_id, project_path, revise_loaded, now, now)
    end
end

"""
    SessionRegistry

Registry of all active Julia REPL sessions.

# Fields
- `sessions::Dict{String, SessionState}`: Map of session name to state
- `current::Union{String, Nothing}`: Name of the currently active session
"""
mutable struct SessionRegistry
    sessions::Dict{String, SessionState}
    current::Union{String, Nothing}
end

"""
    SESSIONS::SessionRegistry

Global session registry. All session operations go through this registry.
"""
const SESSIONS = SessionRegistry(Dict{String,SessionState}(), nothing)

"""
    _INITIAL_PROJECT_PATH::Ref{Union{String,Nothing}}

Stores the initial project path so new sessions can inherit it.
Set by start_server(project_dir=...), which reads JULIA_REPL_PROJECT upstream.
"""
const _INITIAL_PROJECT_PATH = Ref{Union{String,Nothing}}(nothing)

"""
    LogViewerState

State for the optional log viewer feature that displays REPL output in a separate terminal.

# Fields
- `log_path::Union{String, Nothing}`: Path to the log file (default: `~/.julia/logs/repl.log`)
- `log_io::Union{IO, Nothing}`: Open file handle for writing logs
- `mode::Symbol`: Current mode - `:none`, `:file`, or `:tmux`
"""
mutable struct LogViewerState
    log_path::Union{String, Nothing}
    log_io::Union{IO, Nothing}
    mode::Symbol  # :none, :file, :tmux
end

"""
    LOG_VIEWER::LogViewerState

Global state for the log viewer. Configure via `setup_log_viewer!()`.
"""
const LOG_VIEWER = LogViewerState(nothing, nothing, :none)

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
const HIGHLIGHT_CONFIG = HighlightConfig(true, :ansi)

"""
    _init_highlight_config!()

Re-read environment variables into HIGHLIGHT_CONFIG. Called from `__init__()`
to ensure runtime values are used instead of precompilation-cached defaults.
"""
function _init_highlight_config!()
    HIGHLIGHT_CONFIG.enabled = lowercase(get(ENV, "JULIA_REPL_HIGHLIGHT", "true")) == "true"
    HIGHLIGHT_CONFIG.format = _validate_output_format(get(ENV, "JULIA_REPL_OUTPUT_FORMAT", "ansi"))
    nothing
end
