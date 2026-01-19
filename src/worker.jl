# worker.jl - Distributed worker lifecycle management

"""
    ensure_worker!() -> Int

Ensure a worker process exists, creating one if needed. Returns the worker ID.
"""
function ensure_worker!()
    if WORKER.worker_id === nothing || !(WORKER.worker_id in workers())
        # Get the current project directory so worker inherits the environment
        project_dir = dirname(Pkg.project().path)

        # Spawn a new worker with the same project environment
        new_workers = addprocs(1; exeflags=`--project=$project_dir`)
        WORKER.worker_id = first(new_workers)

        # Load Pkg on the worker using Core.eval to avoid closure serialization issues
        remotecall_fetch(Core.eval, WORKER.worker_id, Main, :(using Pkg))

        # Activate project if one was set
        if WORKER.project_path !== nothing
            try
                path = WORKER.project_path
                remotecall_fetch(Core.eval, WORKER.worker_id, Main, :(Pkg.activate($path)))
            catch e
                @warn "Failed to activate project on worker" project=WORKER.project_path error=e
            end
        end
    end
    return WORKER.worker_id
end

"""
    kill_worker!()

Kill the current worker process if one exists.
"""
function kill_worker!()
    if WORKER.worker_id !== nothing && WORKER.worker_id in workers()
        rmprocs(WORKER.worker_id)
    end
    WORKER.worker_id = nothing
end

"""
    reset_worker!()

Kill the current worker and spawn a fresh one. Returns the new worker ID.
"""
function reset_worker!()
    kill_worker!()
    return ensure_worker!()
end

"""
    capture_eval_on_worker(code::String) -> (value_str, output, error_str)

Evaluate Julia code on the worker process, capturing both return value and printed output.
Uses Core.eval with expressions to avoid closure serialization issues.
"""
function capture_eval_on_worker(code::String)
    worker_id = ensure_worker!()

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
                close(rd_out)
                close(rd_err)
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

    return remotecall_fetch(Core.eval, worker_id, Main, eval_expr)
end

"""
    get_worker_info() -> NamedTuple

Get information about the current worker session.
"""
function get_worker_info()
    worker_id = ensure_worker!()

    info_expr = quote
        # Get user-defined symbols
        all_names = names(Main; all=true)
        protected = Set([:Base, :Core, :Main, :ans, :include, :eval, :Pkg])
        user_vars = Symbol[]
        for name in all_names
            name_str = string(name)
            if !startswith(name_str, "#") && !startswith(name_str, "_") && !(name in protected)
                push!(user_vars, name)
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
