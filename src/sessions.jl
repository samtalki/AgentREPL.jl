# sessions.jl - Multi-session management

"""
    sync_worker_global!(session::SessionState)

Synchronize the global WORKER state with the given session for backward compatibility.
"""
function sync_worker_global!(session::SessionState)
    WORKER.worker_id = session.worker_id
    WORKER.project_path = session.project_path
end

"""
    get_current_session!() -> SessionState

Get the current active session. If no session exists, creates a "default" session.
"""
function get_current_session!()
    if SESSIONS.current === nothing || !haskey(SESSIONS.sessions, SESSIONS.current)
        return create_session!("default")
    end
    session = SESSIONS.sessions[SESSIONS.current]
    session.last_used = time()
    return session
end

"""
    create_session!(name::String; project_path::Union{String,Nothing}=nothing) -> SessionState

Create a new named session. If a session with this name already exists, returns it.
The worker is NOT spawned here — it's created lazily on first use via `ensure_worker!`.
"""
function create_session!(name::String; project_path::Union{String,Nothing}=nothing)
    if haskey(SESSIONS.sessions, name)
        session = SESSIONS.sessions[name]
        SESSIONS.current = name
        sync_worker_global!(session)
        return session
    end

    # Inherit initial project path from start_server() if no explicit path given
    effective_path = if project_path !== nothing
        project_path
    elseif _INITIAL_PROJECT_PATH[] !== nothing
        _INITIAL_PROJECT_PATH[]
    else
        nothing
    end

    now = time()
    session = SessionState(name, nothing, effective_path, false, now, now)
    SESSIONS.sessions[name] = session
    SESSIONS.current = name
    sync_worker_global!(session)
    return session
end

"""
    switch_session!(name::String) -> SessionState

Switch to an existing session. Throws an error if the session doesn't exist.
"""
function switch_session!(name::String)
    if !haskey(SESSIONS.sessions, name)
        error("Session '$name' does not exist. Available sessions: $(join(keys(SESSIONS.sessions), ", "))")
    end
    session = SESSIONS.sessions[name]
    SESSIONS.current = name
    session.last_used = time()
    sync_worker_global!(session)
    return session
end

"""
    destroy_session!(name::String)

Destroy a session, killing its worker process. Cannot destroy the current session
if it's the only one — switch first.
"""
function destroy_session!(name::String)
    if !haskey(SESSIONS.sessions, name)
        error("Session '$name' does not exist.")
    end

    session = SESSIONS.sessions[name]

    if session.worker_id !== nothing && session.worker_id in workers()
        rmprocs(session.worker_id)
    end

    delete!(SESSIONS.sessions, name)

    if SESSIONS.current == name
        if isempty(SESSIONS.sessions)
            SESSIONS.current = nothing
            WORKER.worker_id = nothing
            WORKER.project_path = nothing
        else
            new_current = first(keys(SESSIONS.sessions))
            SESSIONS.current = new_current
            sync_worker_global!(SESSIONS.sessions[new_current])
        end
    end
end

"""
    list_sessions() -> Vector{NamedTuple}

List all sessions with summary information.
"""
function list_sessions()
    results = NamedTuple{(:name, :worker_id, :project, :revise, :is_current, :age_seconds), Tuple{String, Union{Int,Nothing}, Union{String,Nothing}, Bool, Bool, Float64}}[]

    for (name, session) in SESSIONS.sessions
        push!(results, (
            name = name,
            worker_id = session.worker_id,
            project = session.project_path,
            revise = session.revise_loaded,
            is_current = (name == SESSIONS.current),
            age_seconds = time() - session.created_at
        ))
    end

    sort!(results; by = r -> r.name)
    return results
end

"""
    get_session(name::String) -> SessionState

Get a session by name. Throws an error if it doesn't exist.
"""
function get_session(name::String)
    if !haskey(SESSIONS.sessions, name)
        error("Session '$name' does not exist. Available sessions: $(join(keys(SESSIONS.sessions), ", "))")
    end
    return SESSIONS.sessions[name]
end

"""
    resolve_session(session_name::Union{String,Nothing}) -> SessionState

Resolve a session parameter: if a name is given, look it up; otherwise use current session.
"""
function resolve_session(session_name::Union{String,Nothing}=nothing)
    if session_name !== nothing
        return get_session(session_name)
    end
    return get_current_session!()
end

"""
    _cleanup_all_workers!()

Kill all worker processes across all sessions. Called via atexit() hook
to prevent orphan Julia processes when the MCP server exits.
"""
function _cleanup_all_workers!()
    # Batch rmprocs so total wait is bounded at 5s regardless of session count
    ids = Int[s.worker_id for (_, s) in SESSIONS.sessions
              if s.worker_id !== nothing && s.worker_id in workers()]
    try
        isempty(ids) || rmprocs(ids; waitfor=5.0)
    catch
    end
    try
        close_log_viewer!()
    catch
    end
end
