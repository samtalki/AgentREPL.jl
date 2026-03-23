# worker.jl - Distributed worker lifecycle management

"""
    ensure_worker!(session::SessionState) -> Int

Ensure a worker process exists for the given session, creating one if needed.
Returns the worker ID. Also attempts to load Revise.jl on the worker.
"""
function ensure_worker!(session::SessionState)
    if session.worker_id === nothing || !(session.worker_id in workers())
        project_dir = dirname(Pkg.project().path)
        new_workers = addprocs(1; exeflags=`--project=$project_dir`)
        session.worker_id = first(new_workers)

        # Core.eval avoids closure serialization issues with remotecall
        remotecall_fetch(Core.eval, session.worker_id, Main, :(using Pkg))

        try
            remotecall_fetch(Core.eval, session.worker_id, Main, :(using Revise))
            session.revise_loaded = true
        catch e
            session.revise_loaded = false
            if e isa Distributed.RemoteException || e isa Distributed.ProcessExitedException
                @warn "Worker may have crashed while loading Revise.jl" session=session.name exception=(e, catch_backtrace())
            end
        end

        if session.project_path !== nothing
            try
                path = session.project_path
                remotecall_fetch(Core.eval, session.worker_id, Main, :(Pkg.activate($path)))
            catch e
                # Intentionally preserve project_path so a transient activation failure
                # (e.g., missing Manifest.toml) can succeed on next worker spawn after
                # the user runs pkg(action="instantiate")
                @warn "Failed to activate project on worker — will retry on next worker spawn" project=session.project_path error=e
            end
        end

        session.last_used = time()
    end
    return session.worker_id
end

"""
    kill_worker!(session::SessionState)

Kill the worker process for the given session.
"""
function kill_worker!(session::SessionState)
    if session.worker_id !== nothing && session.worker_id in workers()
        try
            rmprocs(session.worker_id)
        catch e
            @warn "Failed to cleanly kill worker" session=session.name worker_id=session.worker_id exception=(e, catch_backtrace())
        end
    end
    session.worker_id = nothing
    session.revise_loaded = false
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
    _with_output_capture(body_expr::Expr) -> Expr

Generate a quote block that wraps `body_expr` with stdout/stderr capture.
The returned expression evaluates to `(body_result, stdout_string, stderr_string)`.
Used at quote construction time — spliced into remote eval expressions via \$().
"""
function _with_output_capture(body_expr::Expr)
    quote
        let
            _woc_old_stdout = stdout
            _woc_old_stderr = stderr
            _woc_rd_out, _woc_wr_out = redirect_stdout()
            _woc_rd_err, _woc_wr_err = redirect_stderr()
            _woc_body_result = try
                $body_expr
            finally
                redirect_stdout(_woc_old_stdout)
                redirect_stderr(_woc_old_stderr)
                close(_woc_wr_out)
                close(_woc_wr_err)
            end
            _woc_stdout = try; String(read(_woc_rd_out)); catch; "[output capture failed]"; end
            _woc_stderr = try; String(read(_woc_rd_err)); catch; "[stderr capture failed]"; end
            try; close(_woc_rd_out); catch; end
            try; close(_woc_rd_err); catch; end
            (_woc_body_result, _woc_stdout, _woc_stderr)
        end
    end
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

    eval_expr = quote
        let code_str = $code
            (_eval_value, _eval_err, _eval_bt), stdout_content, stderr_content = $(_with_output_capture(quote
                _eval_value = nothing
                _eval_err = nothing
                _eval_bt = nothing
                try
                    _eval_value = include_string(Main, code_str, "julia_eval")
                catch e
                    _eval_err = e
                    _eval_bt = catch_backtrace()
                end
                (_eval_value, _eval_err, _eval_bt)
            end))

            combined_output = stdout_content
            if !isempty(stderr_content)
                combined_output *= "\n[stderr]\n" * stderr_content
            end

            error_str = _eval_err === nothing ? nothing : sprint(showerror, _eval_err, _eval_bt)
            value_str = try
                repr(_eval_value)
            catch repr_err
                try
                    string(_eval_value)
                catch str_err
                    "<$(typeof(_eval_value))>"
                end
            end

            (value_str, combined_output, error_str)
        end
    end

    local value_str, output, error_str

    elapsed = @elapsed begin
        if timeout === nothing
            # No timeout: blocking remotecall_fetch with crash protection
            try
                value_str, output, error_str = remotecall_fetch(Core.eval, worker_id, Main, eval_expr)
            catch e
                if e isa Distributed.ProcessExitedException
                    session.worker_id = nothing
                    session.revise_loaded = false
                    value_str = "nothing"
                    output = ""
                    error_str = "Worker process crashed. It will respawn on next eval. Error: $(sprint(showerror, e))"
                else
                    rethrow()
                end
            end
        else
            # With timeout: race remotecall against a cancellable Timer
            result_channel = Channel{Any}(1)
            future = remotecall(Core.eval, worker_id, Main, eval_expr)

            # Timer fires after timeout. Race safety comes from the Channel(1) —
            # only the first put! succeeds. close(timer) is best-effort cleanup.
            timer = Timer(timeout) do _
                try; put!(result_channel, (:timeout, nothing)); catch; end
            end

            @async begin
                try
                    result = fetch(future)
                    put!(result_channel, (:ok, result))
                catch e
                    try
                        put!(result_channel, (:error, e))
                    catch put_err
                        @warn "Failed to report async eval error (channel may be closed)" exception=(e, catch_backtrace())
                    end
                end
            end

            tag, payload = take!(result_channel)
            close(timer)
            close(result_channel)

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
