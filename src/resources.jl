# resources.jl - MCP resources exposing session state to the client.
#
# Resources let Claude Code pull session state into context (e.g. @-mention) without
# spending an eval/info tool call. Each data_provider is zero-arg and reads live
# state; the framework JSON-encodes whatever it returns, so providers return
# NamedTuples (mime_type "application/json").
#
# Contract:
# - A resource READ has no side effects: providers never spawn a worker. When no
#   live worker exists they report what is known without forcing one, so an
#   @-mention cannot cold-start a Julia process.
# - Providers never throw. `_resource_safe` wraps each: success is tagged
#   `ok = true`, failure is `(ok = false, error = ...)`. The `ok` flag is a
#   dedicated discriminant that cannot collide with a payload field.
# - Any worker access goes through `get_worker_info` (which self-heals on crash),
#   guarded by `worker_live`, never a raw `_remote_eval_fetch`.

"""
    _resource_safe(f) -> NamedTuple

Run a resource data_provider body. On success returns its NamedTuple tagged with
`ok = true`; on failure returns `(ok = false, error = ...)`. Keeps `resources/read`
from hard-failing while giving the client an unambiguous success/failure flag.
`InterruptException`/`OutOfMemoryError` propagate (never swallowed into `error`).
"""
function _resource_safe(f)
    try
        return merge((ok = true,), f())
    catch e
        e isa InterruptException && rethrow()
        e isa OutOfMemoryError && rethrow()
        return (ok = false, error = sprint(showerror, e))
    end
end

# --- data providers ---

_resource_sessions() = _resource_safe() do
    (sessions = [(
        name = s.name,
        worker_pid = s.worker_pid,
        project = s.project,
        revise_loaded = s.revise,
        is_current = s.is_current,
        age_seconds = round(s.age_seconds; digits=1),
    ) for s in list_sessions()],
     current = SESSIONS.current)
end

_resource_variables() = _resource_safe() do
    session = get_current_session!()
    live = worker_live(session)
    vars = live ?
        [(name = string(v.name), type = v.type, size = v.size) for v in get_worker_info(session).variables] :
        NamedTuple{(:name, :type, :size), Tuple{String,String,String}}[]
    (session = session.name, worker_spawned = live, variables = vars)
end

_resource_info() = _resource_safe() do
    session = get_current_session!()
    live = worker_live(session)
    modules = 0
    project = something(session.project_path, "(default)")
    if live
        wi = get_worker_info(session)  # worker already live → no spawn
        modules = wi.modules
        project = wi.project
    end
    (session = session.name,
     is_current = session.name == SESSIONS.current,
     worker_spawned = live,
     julia_version = string(VERSION),  # worker shares this Julia binary
     project = project,
     loaded_modules = modules,
     revise_loaded = session.revise_loaded,
     worker_pid = worker_pid(session),
     eval_count = length(session.eval_timings),
     notes = copy(session.worker_notes))
end

_resource_project() = _resource_safe() do
    session = get_current_session!()
    dir = session.project_path
    if dir === nothing && worker_live(session)
        dir = get_worker_info(session).project
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
    # `recent_output` always available: out-of-band worker output (spawn-time
    # precompile, async prints) captured by the drain, even when audit is off.
    recent = copy(session.recent_output)
    if _AUDIT_DIR[] === nothing
        return (session = session.name, audit_enabled = false, recent_output = recent,
                note = "Audit logging is disabled (set JULIA_REPL_AUDIT_DIR for a persistent per-session log). 'recent_output' is recent out-of-band worker output.")
    end
    date_str = Dates.format(Dates.today(), "yyyy-mm-dd")
    path = joinpath(_AUDIT_DIR[], "$(session.name)_$(date_str).log")
    if !isfile(path)
        return (session = session.name, audit_enabled = true, path = path, tail = String[],
                recent_output = recent, note = "No audit entries yet today.")
    end
    lines = readlines(path)
    tail = length(lines) > 200 ? lines[end-199:end] : lines
    (session = session.name, audit_enabled = true, path = path, tail = tail, recent_output = recent)
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
            description = "User-defined variables in the current session (name, type, size). Empty until a worker is spawned; reading does not spawn one.",
            mime_type = "application/json", data_provider = _resource_variables),
        MCPResource(; uri = "agentrepl://session/info",
            name = "Current session info",
            description = "Julia version, active project, loaded module count, Revise status, worker pid, and setup notes for the current session. Reading does not spawn a worker.",
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
