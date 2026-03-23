# revise.jl - Revise.jl integration for hot-reloading

"""
    is_revise_available(session::SessionState) -> Bool

Check if Revise.jl is loaded on the session's worker.
"""
function is_revise_available(session::SessionState)
    return session.revise_loaded && session.worker_id !== nothing && session.worker_id in workers()
end

"""
    revise_on_worker!(session::SessionState) -> NamedTuple

Trigger Revise.revise() on the worker to pick up file changes.
Returns (success, message).
"""
function revise_on_worker!(session::SessionState)
    if !is_revise_available(session)
        return (success = false, message = "Revise.jl is not available in session '$(session.name)'. Install it with: pkg(action=\"add\", packages=\"Revise\")")
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
    track_file_on_worker!(session::SessionState, filepath::String) -> NamedTuple

Start tracking a file with Revise on the worker.
Returns (success, message).
"""
function track_file_on_worker!(session::SessionState, filepath::String)
    if !is_revise_available(session)
        return (success = false, message = "Revise.jl is not available in session '$(session.name)'. Install it with: pkg(action=\"add\", packages=\"Revise\")")
    end

    try
        result = remotecall_fetch(Core.eval, session.worker_id, Main, quote
            let fp = $filepath
                try
                    Revise.track(Main, fp)
                    (success = true, message = "Now tracking '$fp' with Revise. Changes will be auto-loaded on revise().")
                catch e
                    (success = false, message = sprint(showerror, e))
                end
            end
        end)
        return result
    catch e
        return (success = false, message = "Error tracking file: $(sprint(showerror, e))")
    end
end

"""
    includet_on_worker!(session::SessionState, filepath::String) -> NamedTuple

Include a file with Revise tracking (hot-reloadable include).
Returns (success, message).
"""
function includet_on_worker!(session::SessionState, filepath::String)
    if !is_revise_available(session)
        return (success = false, message = "Revise.jl is not available in session '$(session.name)'. Install it with: pkg(action=\"add\", packages=\"Revise\")")
    end

    try
        result = remotecall_fetch(Core.eval, session.worker_id, Main, quote
            let fp = $filepath
                try
                    Revise.includet(fp)
                    (success = true, message = "Included and tracking '$fp'. Changes will be auto-loaded on revise().")
                catch e
                    (success = false, message = sprint(showerror, e))
                end
            end
        end)
        return result
    catch e
        return (success = false, message = "Error including file: $(sprint(showerror, e))")
    end
end

"""
    get_revise_status(session::SessionState) -> NamedTuple

Get Revise.jl tracking status on the worker.
Returns (available, tracked_files, watched_packages).
"""
function get_revise_status(session::SessionState)
    if !is_revise_available(session)
        return (available = false, tracked_files = String[], watched_packages = String[])
    end

    try
        result = remotecall_fetch(Core.eval, session.worker_id, Main, quote
            try
                watched = String[]
                for (pkg, files) in Revise.watched_files
                    for f in files
                        push!(watched, string(f))
                    end
                end
                tracked_pkgs = String[string(p.name) for p in keys(Revise.pkgdatas)]
                (available = true, tracked_files = watched, watched_packages = tracked_pkgs)
            catch e
                (available = true, tracked_files = String[], watched_packages = String[])
            end
        end)
        return result
    catch e
        return (available = false, tracked_files = String[], watched_packages = String[])
    end
end
