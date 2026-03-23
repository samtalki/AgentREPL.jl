# worker.jl - Distributed worker lifecycle management

"""
    ensure_worker!(session::SessionState) -> Int

Ensure a worker process exists for the given session, creating one if needed.
Returns the worker ID. Also attempts to load Revise.jl on the worker.
"""
function ensure_worker!(session::SessionState)
    if session.worker_id === nothing || !(session.worker_id in workers())
        # Get the current project directory so worker inherits the environment
        project_dir = dirname(Pkg.project().path)

        # Spawn a new worker with the same project environment
        new_workers = addprocs(1; exeflags=`--project=$project_dir`)
        session.worker_id = first(new_workers)

        # Load Pkg on the worker using Core.eval to avoid closure serialization issues
        remotecall_fetch(Core.eval, session.worker_id, Main, :(using Pkg))

        # Try to load Revise.jl for hot-reloading support
        try
            remotecall_fetch(Core.eval, session.worker_id, Main, :(using Revise))
            session.revise_loaded = true
        catch
            session.revise_loaded = false
        end

        # Activate project if one was set
        if session.project_path !== nothing
            try
                path = session.project_path
                remotecall_fetch(Core.eval, session.worker_id, Main, :(Pkg.activate($path)))
            catch e
                @warn "Failed to activate project on worker" project=session.project_path error=e
                session.project_path = nothing
            end
        end

        session.last_used = time()
        sync_worker_global!(session)
    end
    return session.worker_id
end

"""
    ensure_worker!() -> Int

Ensure a worker process exists for the current session. Returns the worker ID.
"""
function ensure_worker!()
    session = get_current_session!()
    return ensure_worker!(session)
end

"""
    kill_worker!(session::SessionState)

Kill the worker process for the given session.
"""
function kill_worker!(session::SessionState)
    if session.worker_id !== nothing && session.worker_id in workers()
        rmprocs(session.worker_id)
    end
    session.worker_id = nothing
    session.revise_loaded = false
    sync_worker_global!(session)
end

"""
    kill_worker!()

Kill the current session's worker process.
"""
function kill_worker!()
    session = get_current_session!()
    kill_worker!(session)
end

"""
    reset_worker!(session::SessionState) -> Int

Kill the session's worker and spawn a fresh one. Returns the new worker ID.
"""
function reset_worker!(session::SessionState)
    kill_worker!(session)
    return ensure_worker!(session)
end

"""
    reset_worker!() -> Int

Kill the current session's worker and spawn a fresh one. Returns the new worker ID.
"""
function reset_worker!()
    session = get_current_session!()
    return reset_worker!(session)
end

"""
    capture_eval_on_worker(code::String; timeout::Union{Float64,Nothing}=nothing, session_name::Union{String,Nothing}=nothing) -> (value_str, output, error_str, elapsed)

Evaluate Julia code on the worker process, capturing both return value and printed output.
Uses Core.eval with expressions to avoid closure serialization issues.

Returns a 4-tuple: (value_str, output, error_str, elapsed_seconds).

If `timeout` is set (in seconds), the worker is killed after the timeout and a TimeoutError is returned.
If `session_name` is given, evaluates on that session's worker; otherwise uses the current session.
"""
function capture_eval_on_worker(code::String; timeout::Union{Float64,Nothing}=nothing, session_name::Union{String,Nothing}=nothing)
    session = resolve_session(session_name)
    worker_id = ensure_worker!(session)
    session.last_used = time()

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
                # Wrap each close in try-catch to prevent masking errors
                try; close(rd_out); catch; end
                try; close(rd_err); catch; end
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

    local value_str, output, error_str

    elapsed = @elapsed begin
        if timeout === nothing
            # No timeout: blocking remotecall_fetch (original behavior)
            value_str, output, error_str = remotecall_fetch(Core.eval, worker_id, Main, eval_expr)
        else
            # With timeout: race remotecall against a timer
            result_channel = Channel{Any}(2)
            future = remotecall(Core.eval, worker_id, Main, eval_expr)

            # Race: eval completion vs timeout
            @async begin
                try
                    result = fetch(future)
                    put!(result_channel, (:ok, result))
                catch e
                    try; put!(result_channel, (:error, e)); catch; end
                end
            end

            @async begin
                sleep(timeout)
                try; put!(result_channel, (:timeout, nothing)); catch; end
            end

            tag, payload = take!(result_channel)
            close(result_channel)  # Signal the losing task to stop

            if tag == :ok
                value_str, output, error_str = payload
            elseif tag == :error
                value_str = "nothing"
                output = ""
                error_str = sprint(showerror, payload)
            else  # :timeout
                kill_worker!(session)
                value_str = "nothing"
                output = ""
                error_str = "TimeoutError: evaluation exceeded $(timeout)s timeout. Worker was killed and will respawn on next eval."
            end
        end
    end

    return (value_str, output, error_str, elapsed)
end

"""
    get_worker_info(session::SessionState) -> NamedTuple

Get information about the given session's worker.
"""
function get_worker_info(session::SessionState)
    worker_id = ensure_worker!(session)

    info_expr = quote
        # Get user-defined symbols with type and size info
        all_names = names(Main; all=true)
        protected = Set([:Base, :Core, :Main, :ans, :include, :eval, :Pkg, :Revise])
        user_vars = NamedTuple{(:name, :type, :size), Tuple{Symbol, String, String}}[]
        for name in all_names
            name_str = string(name)
            if !startswith(name_str, "#") && !startswith(name_str, "_") && !(name in protected)
                val = try; Core.eval(Main, name); catch; nothing; end
                type_str = try; string(typeof(val)); catch; "?"; end
                size_str = try
                    if applicable(size, val) && !(val isa AbstractString)
                        s = size(val)
                        if !isempty(s)
                            length(s) > 1 ? string(s) : "length=$(length(val))"
                        else
                            ""
                        end
                    elseif applicable(length, val)
                        "length=$(length(val))"
                    else
                        ""
                    end
                catch
                    ""
                end
                push!(user_vars, (name=name, type=type_str, size=size_str))
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
    get_worker_info() -> NamedTuple

Get information about the current session's worker.
"""
function get_worker_info()
    session = get_current_session!()
    return get_worker_info(session)
end
