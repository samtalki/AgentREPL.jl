# resources.jl - MCP resources exposing session state to the client.
#
# Resources let Claude Code pull session state into context (e.g. @-mention) without
# spending an eval/info tool call. Each data_provider is zero-arg and reads live
# state; the framework JSON-encodes whatever it returns, so providers return
# NamedTuples/Dicts (mime_type "application/json"). Providers never throw — failures
# come back as an `error` field so a resource read degrades instead of erroring.

"""
    _resource_safe(f) -> Any

Run a resource data_provider body, returning its value or an `(error = ...)`
NamedTuple if it throws. Keeps `resources/read` from hard-failing.
"""
function _resource_safe(f)
    try
        return f()
    catch e
        e isa InterruptException && rethrow()
        e isa OutOfMemoryError && rethrow()
        return (error = sprint(showerror, e),)
    end
end

# --- data providers ---

_resource_sessions() = _resource_safe() do
    (sessions = [(
        name = s.name,
        worker_pid = s.worker_id,
        project = s.project,
        revise = s.revise,
        is_current = s.is_current,
        age_seconds = round(s.age_seconds; digits=1),
    ) for s in list_sessions()],
     current = SESSIONS.current)
end

_resource_variables() = _resource_safe() do
    session = get_current_session!()
    info = get_worker_info(session)
    (session = session.name,
     variables = [(name = string(v.name), type = v.type, size = v.size) for v in info.variables])
end

_resource_info() = _resource_safe() do
    session = get_current_session!()
    info = get_worker_info(session)
    (session = session.name,
     is_current = session.name == SESSIONS.current,
     julia_version = info.version,
     project = info.project,
     loaded_modules = info.modules,
     revise_loaded = session.revise_loaded,
     worker_pid = worker_pid(session),
     eval_count = length(session.eval_timings),
     notes = copy(session.worker_notes))
end

_resource_project() = _resource_safe() do
    session = get_current_session!()
    dir = session.project_path
    if dir === nothing
        info = get_worker_info(session)
        dir = info.project
    end
    project_toml = ""
    manifest_present = false
    if dir !== nothing && isdir(dir)
        ptoml = joinpath(dir, "Project.toml")
        isfile(ptoml) && (project_toml = read(ptoml, String))
        manifest_present = isfile(joinpath(dir, "Manifest.toml"))
    end
    (session = session.name, project_dir = dir,
     project_toml = project_toml, manifest_present = manifest_present)
end

_resource_log() = _resource_safe() do
    session = get_current_session!()
    if _AUDIT_DIR[] === nothing
        return (session = session.name, audit_enabled = false,
                note = "Audit logging is disabled. Set JULIA_REPL_AUDIT_DIR to enable a persistent per-session log.")
    end
    date_str = Dates.format(Dates.today(), "yyyy-mm-dd")
    path = joinpath(_AUDIT_DIR[], "$(session.name)_$(date_str).log")
    if !isfile(path)
        return (session = session.name, audit_enabled = true, path = path, tail = String[],
                note = "No audit entries yet today.")
    end
    lines = readlines(path)
    tail = length(lines) > 200 ? lines[end-199:end] : lines
    (session = session.name, audit_enabled = true, path = path, tail = tail)
end

"""
    agentrepl_resources() -> Vector{MCPResource}

Build the MCP resources exposing live session state. Registered in `start_server`.
"""
function agentrepl_resources()
    MCPResource[
        MCPResource(; uri = "agentrepl://sessions",
            name = "Sessions",
            description = "All AgentREPL sessions with worker pid, project, Revise status, and age.",
            mime_type = "application/json", data_provider = _resource_sessions),
        MCPResource(; uri = "agentrepl://session/variables",
            name = "Current session variables",
            description = "User-defined variables in the current session (name, type, size). Spawns the worker if needed.",
            mime_type = "application/json", data_provider = _resource_variables),
        MCPResource(; uri = "agentrepl://session/info",
            name = "Current session info",
            description = "Julia version, active project, loaded module count, Revise status, worker pid, and setup notes for the current session.",
            mime_type = "application/json", data_provider = _resource_info),
        MCPResource(; uri = "agentrepl://session/project",
            name = "Current session project",
            description = "The active project directory, its Project.toml contents, and whether a Manifest.toml is present.",
            mime_type = "application/json", data_provider = _resource_project),
        MCPResource(; uri = "agentrepl://session/log",
            name = "Current session log",
            description = "Recent audit-log entries for the current session (when JULIA_REPL_AUDIT_DIR is set).",
            mime_type = "application/json", data_provider = _resource_log),
    ]
end
