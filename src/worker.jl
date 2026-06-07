# worker.jl - Malt worker lifecycle management

"""
    _remote_eval_fetch(w::Malt.Worker, expr) -> Any

Evaluate `expr` in `Main` on worker `w` and return the result. Thin wrapper over
`Malt.remote_eval_fetch` so every call site uses one spelling of the IPC.
"""
_remote_eval_fetch(w::Malt.Worker, expr) = Malt.remote_eval_fetch(Main, w, expr)

"""
    worker_pid(session::SessionState) -> Union{Int,Nothing}

OS process id of the session's worker, or `nothing` if no worker is running.
Used for display (Malt workers have no integer cluster id like Distributed).
"""
worker_pid(session::SessionState) =
    session.worker === nothing ? nothing : Int(Base.getpid(session.worker.proc))

"""
    worker_live(session::SessionState) -> Bool

Whether the session has a worker that is still running. A non-`nothing` `worker`
may still point at a dead process, so liveness is this two-part check — kept in one
place rather than re-spelled at every call site.
"""
worker_live(session::SessionState) =
    session.worker !== nothing && Malt.isrunning(session.worker)

"""
    _one_line(e) -> String

First line of an exception's message, for compact session notes.
"""
_one_line(e) = first(split(sprint(showerror, e), '\n'; limit=2))

"""
    _unwrap(e) -> Exception

Unwrap a `TaskFailedException` (thrown by `fetch` on a failed task) to the
underlying cause, so worker exceptions are classified by their real type
(`Malt.TerminatedWorkerException`, `Malt.RemoteException`) rather than the wrapper.
"""
_unwrap(e) = e isa TaskFailedException ? e.task.exception : e

"""
    _crash_message(e) -> String

User-facing message for an exception raised while talking to the worker.
Distinguishes the cases so the agent knows whether to fix its code or not:
- terminated worker (crash or `exit()`) → a clear note, not the raw exception;
- a remote error from the harness itself (e.g. the result could not be transported)
  → flagged as a harness issue so it isn't mistaken for a user code error;
- anything else → the plain rendered error.
"""
function _crash_message(e)
    if e isa Malt.TerminatedWorkerException
        return "Worker process terminated (it crashed or called exit()). A fresh worker will spawn on the next eval."
    elseif e isa Malt.RemoteException
        return "AgentREPL could not run or transport this evaluation (a worker-side harness error, not your code):\n" * sprint(showerror, e)
    else
        return sprint(showerror, e)
    end
end

"""
    _clear_worker_state!(session::SessionState)

Clear worker-related fields on a session. Centralizes the paired reset of
`worker`, `revise_loaded`, notes, and the interactive socket so every call site
stays consistent.
"""
function _clear_worker_state!(session::SessionState)
    # Clean up socket file from interactive REPL
    if session.socket_path !== nothing
        try
            rm(session.socket_path; force=true)
        catch e
            @debug "Failed to remove socket file" path=session.socket_path exception=e
        end
        session.socket_path = nothing
    end
    session.worker = nothing
    session.revise_loaded = false
    empty!(session.eval_timings)
    empty!(session.worker_notes)
end

"""
    _handle_worker_crash!(session::SessionState, e)

Reset session worker state if `e` indicates a dead worker. Handles
`Malt.TerminatedWorkerException` and the case where the worker stopped running.
"""
function _handle_worker_crash!(session::SessionState, e)
    if e isa Malt.TerminatedWorkerException || (session.worker !== nothing && !worker_live(session))
        _clear_worker_state!(session)
    end
end

"""
    _start_output_drain!(session_name::String, w::Malt.Worker)

Drain the worker's stdout/stderr pipes so out-of-band output (async tasks,
finalizers, background prints that fire outside an eval's capture window) cannot
fill the pipe buffer and block the worker.

The worker is spawned with `monitor_stdout=false`/`monitor_stderr=false`, so Malt
does NOT reprint worker output onto the host's stdout — which is the MCP JSON-RPC
transport. We route drained lines to our own stderr (safe: never the transport),
where Claude Code collects them in the MCP server log. In-band eval output is
captured separately by `_with_output_capture` and is unaffected.
"""
function _start_output_drain!(session_name::String, w::Malt.Worker)
    for (pipe, label) in ((w.stdout, "stdout"), (w.stderr, "stderr"))
        @async begin
            try
                while Malt.isrunning(w)
                    eof(pipe) && break          # blocks until a byte or EOF; clean close exits
                    line = readline(pipe)
                    isempty(line) && continue
                    try
                        println(stderr, "[worker:$session_name:$label] ", line)
                    catch
                    end
                end
            catch e
                # A clean EOF leaves the loop above; reaching here means an unexpected
                # read error while the worker is still up. Leave a breadcrumb — a
                # silently dead drain is what lets the pipe fill and wedge the worker.
                if Malt.isrunning(w)
                    try
                        println(stderr, "[worker:$session_name:$label] drain stopped on error: ", sprint(showerror, e))
                    catch
                    end
                end
            end
        end
    end
    return nothing
end

"""
    ensure_worker!(session::SessionState; _retry_without_revise::Bool=false) -> Malt.Worker

Ensure a worker process exists for the given session, creating one if needed.
Returns the worker. Also attempts to load Revise.jl on the worker.

The returned worker was alive at return time. A remote-eval failure during the
post-spawn setup (project activation, workspace cd) is recorded as a note and can
leave the worker freshly dead, so callers should treat a `TerminatedWorkerException`
on first use as possible and route it through `_handle_worker_crash!`.

The `_retry_without_revise` flag is internal — it prevents unbounded recursion
when Revise.jl consistently crashes the worker process.
"""
function ensure_worker!(session::SessionState; _retry_without_revise::Bool=false)
    if !worker_live(session)
        empty!(session.worker_notes)
        project_dir = try
            dirname(Pkg.project().path)
        catch e
            e isa InterruptException && rethrow()
            e isa OutOfMemoryError && rethrow()
            error("Cannot determine project directory for session '$(session.name)'. Ensure Julia is started with --project=<path>.")
        end

        w = try
            Malt.Worker(; exeflags=["--project=$project_dir"],
                          monitor_stdout=false, monitor_stderr=false)
        catch e
            error("Failed to spawn worker for session '$(session.name)': $(sprint(showerror, e))")
        end
        session.worker = w
        _start_output_drain!(session.name, w)

        # Load Pkg — required. A failure here means the worker is unusable.
        try
            _remote_eval_fetch(w, :(using Pkg))
        catch e
            @warn "Failed to load Pkg on worker, killing half-initialized worker" session=session.name exception=(e, catch_backtrace())
            try; Malt.stop(w); catch; end
            _clear_worker_state!(session)
            rethrow()
        end

        # Load Revise — optional. Degrade gracefully and record a note.
        if !_retry_without_revise
            try
                _remote_eval_fetch(w, :(using Revise))
                session.revise_loaded = true
            catch e
                session.revise_loaded = false
                push!(session.worker_notes,
                    "Revise.jl not loaded ($(_one_line(e))). Hot-reload is disabled; add it with pkg(action=\"add\", packages=\"Revise\").")
                if e isa Malt.RemoteException
                    @warn "Could not load Revise.jl on worker" session=session.name
                else
                    @warn "Unexpected error loading Revise.jl on worker" session=session.name exception=(e, catch_backtrace())
                end
            end

            # If loading Revise crashed the worker, respawn once without Revise.
            if !worker_live(session)
                _clear_worker_state!(session)
                w2 = ensure_worker!(session; _retry_without_revise=true)
                push!(session.worker_notes,
                    "Loading Revise.jl crashed the worker; respawned without it. Hot-reload is disabled.")
                return w2
            end
        end

        if session.project_path !== nothing
            try
                path = session.project_path
                _remote_eval_fetch(w, :(Pkg.activate($path)))
                # Sync workspace to project directory if not already set
                if session.workspace_path === nothing
                    session.workspace_path = session.project_path
                end
            catch e
                # Preserve project_path so a transient activation failure (e.g. missing
                # Manifest.toml) can succeed on next spawn after pkg(instantiate). Record
                # a note so the user is not silently left in the wrong environment.
                push!(session.worker_notes,
                    "Project activation failed for $(session.project_path) ($(_one_line(e))). Running in the default environment — run pkg(action=\"instantiate\") then reset().")
                @warn "Failed to activate project on worker — will retry on next worker spawn" project=session.project_path error=e
            end
        end

        # Restore workspace (working directory) on the worker
        if session.workspace_path !== nothing
            try
                wpath = session.workspace_path
                _remote_eval_fetch(w, :(cd($wpath)))
            catch e
                push!(session.worker_notes, "Workspace directory $(session.workspace_path) could not be restored; cleared.")
                @warn "Failed to restore workspace on worker, clearing" workspace=session.workspace_path error=e
                session.workspace_path = nothing
            end
        end

        # Snapshot the worker's Main symbols AFTER setup. Malt runs its worker event
        # loop in Main, so its internals (serve, handle, MsgID, …) live there alongside
        # Pkg/Revise; this baseline lets get_worker_info list only user-defined names.
        try
            _remote_eval_fetch(w, :(const _AGENTREPL_BASELINE_NAMES = Set(names(Main; all=true))))
        catch e
            # Without the baseline, get_worker_info would list Malt/Pkg internals as
            # "user variables". Surface the degraded state instead of hiding it.
            @warn "Could not snapshot Main baseline on worker; variable listing may include internals" session=session.name exception=(e, catch_backtrace())
            push!(session.worker_notes, "Variable listing may include internal symbols (baseline snapshot failed).")
        end

        session.last_used = time()
    end
    return session.worker
end

"""
    kill_worker!(session::SessionState)

Stop the worker process for the given session. `Malt.stop` escalates
exit → SIGTERM → SIGKILL on its own.
"""
function kill_worker!(session::SessionState)
    if worker_live(session)
        try
            Malt.stop(session.worker)
        catch e
            @warn "Failed to cleanly stop worker, forcing kill" session=session.name exception=(e, catch_backtrace())
            try; Malt.kill(session.worker); catch; end
        end
    end
    _clear_worker_state!(session)
end

"""
    reset_worker!(session::SessionState) -> Malt.Worker

Kill the session's worker and spawn a fresh one. Returns the new worker.
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
    capture_eval_on_worker(code::String; timeout=nothing, session_name=nothing, isolated=false) -> (value_str, output, error_str, elapsed)

Evaluate Julia code on the worker process, capturing both return value and printed output.
Uses Malt expression evaluation to avoid closure serialization issues.

Returns a 4-tuple: (value_str, output, error_str, elapsed_seconds).

If `timeout` is set (in seconds), the worker is killed after the timeout and a TimeoutError is returned.
If `session_name` is given, evaluates on that session's worker; otherwise uses the current session.
If `isolated` is true, evaluates in a fresh anonymous module instead of Main (variables don't persist).
"""
function capture_eval_on_worker(code::String; timeout::Union{Float64,Nothing}=nothing,
                                 session_name::Union{String,Nothing}=nothing, isolated::Bool=false)
    session = resolve_session(session_name)
    worker = ensure_worker!(session)
    session.last_used = time()

    # Pass color preference to worker so repr uses ANSI for color-aware types (UnicodePlots, etc.)
    use_color = is_highlighting_enabled() && get_output_format() == :ansi

    eval_expr = quote
        let code_str = $code, _use_color = $use_color, _isolated = $isolated
            (_eval_value, _eval_err, _eval_bt), stdout_content, stderr_content = $(_with_output_capture(quote
                _eval_value = nothing
                _eval_err = nothing
                _eval_bt = nothing
                try
                    if _isolated
                        # Evaluate in a fresh module — variables don't persist to Main
                        _sandbox = Module(:AgentREPLSandbox, true)  # imports Base and Core
                        _eval_value = include_string(_sandbox, code_str, "julia_eval")
                    else
                        _eval_value = include_string(Main, code_str, "julia_eval")
                    end
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
                if _use_color
                    sprint(io -> show(IOContext(io, :color => true, :compact => true, :limit => true), MIME"text/plain"(), _eval_value))
                else
                    repr(_eval_value)
                end
            catch repr_err
                try
                    string(_eval_value)
                catch str_err
                    # Both show and string threw — surface that display failed (often a
                    # bug in the value's own show method) instead of an opaque placeholder.
                    "<$(typeof(_eval_value)): display threw $(typeof(str_err))>"
                end
            end

            (value_str, combined_output, error_str)
        end
    end

    local value_str, output, error_str

    elapsed = @elapsed begin
        if timeout === nothing
            # No timeout: blocking remote eval with crash protection
            try
                value_str, output, error_str = _remote_eval_fetch(worker, eval_expr)
            catch e
                _handle_worker_crash!(session, e)
                value_str = "nothing"
                output = ""
                error_str = _crash_message(e)
            end
        else
            # With timeout: race the remote eval against a cancellable Timer
            result_channel = Channel{Any}(1)
            future = Malt.remote_eval(Main, worker, eval_expr)

            # Timer fires after timeout. Race safety comes from the Channel(1) —
            # only the first put! succeeds. close(timer) is best-effort cleanup.
            timer = Timer(timeout) do _
                try; put!(result_channel, (:timeout, nothing)); catch; end
            end

            @async begin
                try
                    result = fetch(future)
                    isopen(result_channel) && put!(result_channel, (:ok, result))
                catch e
                    try
                        isopen(result_channel) && put!(result_channel, (:error, _unwrap(e)))
                    catch put_err
                        @debug "timeout-race: result task could not deliver (channel closed)" exception=put_err
                    end
                end
            end

            tag, payload = take!(result_channel)
            close(timer)
            # Resolve the boundary race: if the eval actually finished right as the
            # timer fired, prefer the real outcome over reporting a timeout (a crash
            # at the deadline must not be mislabeled "your code ran too long").
            if tag == :timeout && istaskdone(future)
                try
                    payload = fetch(future)
                    tag = :ok
                catch e
                    payload = _unwrap(e)
                    tag = :error
                end
            end
            close(result_channel)

            if tag == :ok
                value_str, output, error_str = payload
            elseif tag == :error
                _handle_worker_crash!(session, payload)
                value_str = "nothing"
                output = ""
                error_str = _crash_message(payload)
            else  # :timeout
                kill_worker!(session)
                value_str = "nothing"
                output = ""
                error_str = "TimeoutError: evaluation exceeded $(timeout)s timeout. Worker was killed and will respawn on next eval."
            end
        end
    end

    push!(session.eval_timings, elapsed)
    length(session.eval_timings) > MAX_EVAL_TIMINGS && popfirst!(session.eval_timings)

    return (value_str, output, error_str, elapsed)
end

"""
    get_worker_info(session::SessionState) -> NamedTuple

Get information about the given session's worker.
"""
function get_worker_info(session::SessionState)
    worker = ensure_worker!(session)

    # Wrapped in `let` so these temporaries don't leak into the worker's Main
    # (which would then show up as bogus "user variables").
    info_expr = quote
        let
            all_names = names(Main; all=true)
            protected = Set([:Base, :Core, :Main, :ans, :include, :eval, :Pkg, :Revise])
            baseline = isdefined(Main, :_AGENTREPL_BASELINE_NAMES) ? Main._AGENTREPL_BASELINE_NAMES : Set{Symbol}()
            user_vars = NamedTuple{(:name, :type, :size), Tuple{Symbol, String, String}}[]
            for name in all_names
                name_str = string(name)
                if !startswith(name_str, "#") && !startswith(name_str, "_") && !(name in protected) && !(name in baseline)
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

            project_path = try
                dirname(Pkg.project().path)
            catch
                "(no project)"
            end

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
    end

    try
        return _remote_eval_fetch(worker, info_expr)
    catch e
        _handle_worker_crash!(session, e)
        rethrow()
    end
end
