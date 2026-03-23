# revise.jl - Revise.jl integration for hot-reloading

"""
    is_revise_available(session::SessionState) -> Bool

Check if Revise.jl is loaded on the session's worker.
"""
function is_revise_available(session::SessionState)
    return session.revise_loaded && session.worker_id !== nothing && session.worker_id in workers()
end

_revise_unavailable_msg(session::SessionState) =
    "Revise.jl is not available in session '$(session.name)'. Install it with: pkg(action=\"add\", packages=\"Revise\")"

"""
    revise_on_worker!(session::SessionState) -> NamedTuple

Trigger Revise.revise() on the worker to pick up file changes.
Returns (success, message).
"""
function revise_on_worker!(session::SessionState)
    if !is_revise_available(session)
        return (success = false, message = _revise_unavailable_msg(session))
    end

    try
        result = remotecall_fetch(Core.eval, session.worker_id, Main, quote
            try
                Revise.revise()
                (success = true, message = "Revise completed — all tracked file changes have been loaded.")
            catch e
                (success = false, message = sprint(showerror, e))
            end
        end)
        return result
    catch e
        return (success = false, message = "Error calling Revise.revise(): $(sprint(showerror, e))")
    end
end

"""
    _revise_file_action(session::SessionState, filepath::String, action::Symbol) -> NamedTuple

Shared implementation for track and includet actions.
"""
function _revise_file_action(session::SessionState, filepath::String, action::Symbol)
    if !is_revise_available(session)
        return (success = false, message = _revise_unavailable_msg(session))
    end

    action_expr = if action == :track
        :(Revise.track(Main, fp))
    else
        :(Revise.includet(fp))
    end

    verb = action == :track ? "tracking" : "including"
    success_msg = action == :track ?
        "Now tracking '\$fp' with Revise. Changes will be auto-loaded on revise()." :
        "Included and tracking '\$fp'. Changes will be auto-loaded on revise()."

    try
        result = remotecall_fetch(Core.eval, session.worker_id, Main, quote
            let fp = $filepath
                try
                    $action_expr
                    (success = true, message = $success_msg)
                catch e
                    (success = false, message = sprint(showerror, e))
                end
            end
        end)
        return result
    catch e
        return (success = false, message = "Error $verb file: $(sprint(showerror, e))")
    end
end

"""
    track_file_on_worker!(session::SessionState, filepath::String) -> NamedTuple

Start tracking a file with Revise on the worker.
Returns (success, message).
"""
track_file_on_worker!(session::SessionState, filepath::String) =
    _revise_file_action(session, filepath, :track)

"""
    includet_on_worker!(session::SessionState, filepath::String) -> NamedTuple

Include a file with Revise tracking (hot-reloadable include).
Returns (success, message).
"""
includet_on_worker!(session::SessionState, filepath::String) =
    _revise_file_action(session, filepath, :includet)

"""
    get_revise_status(session::SessionState) -> NamedTuple

Get Revise.jl tracking status on the worker.
Returns (available, tracked_files, watched_packages, note).
"""
function get_revise_status(session::SessionState)
    if !is_revise_available(session)
        return (available = false, tracked_files = String[], watched_packages = String[], note = "")
    end

    try
        result = remotecall_fetch(Core.eval, session.worker_id, Main, quote
            try
                watched = String[]
                # NOTE: Revise.watched_files and Revise.pkgdatas are internal APIs,
                # not part of Revise's public interface. The try/catch guards against
                # API changes between Revise versions.
                for (pkg, files) in Revise.watched_files
                    for f in files
                        push!(watched, string(f))
                    end
                end
                tracked_pkgs = String[string(p.name) for p in keys(Revise.pkgdatas)]
                (available = true, tracked_files = watched, watched_packages = tracked_pkgs, note = "")
            catch e
                (available = true, tracked_files = String[], watched_packages = String[], note = "Revise API error: $(sprint(showerror, e))")
            end
        end)
        return result
    catch e
        return (available = false, tracked_files = String[], watched_packages = String[],
                note = "Failed to query Revise status: $(sprint(showerror, e))")
    end
end
