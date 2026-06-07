# packages.jl - Package management and project activation

"""
    activate_project_on_worker!(path::String; session_name::Union{String,Nothing}=nothing)

Activate a Julia project/environment on the worker.

Supports:
- Regular paths: "/path/to/project", "./relative/path"
- Current directory: "." or "@."
- Shared environments: "@v1.12", "@myenv" (expands to ~/.julia/environments/...)
"""
function activate_project_on_worker!(path::String; session_name::Union{String,Nothing}=nothing)
    session = resolve_session(session_name)
    worker = ensure_worker!(session)

    # Handle shared environment syntax (@v1.12, @myenv, etc.)
    # The @ prefix syntax only works in Pkg REPL mode, not programmatically
    resolved_path = if startswith(path, "@") && path != "@."
        env_name = path[2:end]  # Strip the @ prefix
        joinpath(homedir(), ".julia", "environments", env_name)
    else
        path
    end

    activate_expr = quote
        let p = $resolved_path
            try
                Pkg.activate(p)
                project_dir = dirname(Pkg.project().path)
                try
                    cd(project_dir)
                catch cd_err
                    @warn "cd to project directory failed (activation succeeded)" dir=project_dir exception=cd_err
                end
                (success = true, project = project_dir)
            catch e
                (success = false, error = sprint(showerror, e))
            end
        end
    end

    try
        result = _remote_eval_fetch(worker, activate_expr)
        if result.success
            session.project_path = result.project
            session.workspace_path = result.project
        end
        return result
    catch e
        _handle_worker_crash!(session, e)
        return (success = false, error = "Pkg.activate failed — $(_crash_message(e))")
    end
end

"""
    run_pkg_action_on_worker(action::String, pkg_list::Vector{String}; session_name::Union{String,Nothing}=nothing)

Run a Pkg action on the worker process.
"""
function run_pkg_action_on_worker(action::String, pkg_list::Vector{String}; session_name::Union{String,Nothing}=nothing)
    session = resolve_session(session_name)
    worker = ensure_worker!(session)

    pkg_expr = quote
        let act = $action, pkgs = $pkg_list
            _pkg_err, stdout_content, stderr_content = $(_with_output_capture(quote
                _pkg_err = nothing
                try
                    if act == "add"
                        Pkg.add(pkgs)
                    elseif act == "rm"
                        Pkg.rm(pkgs)
                    elseif act == "status"
                        Pkg.status()
                    elseif act == "update"
                        if isempty(pkgs)
                            Pkg.update()
                        else
                            Pkg.update(pkgs)
                        end
                    elseif act == "instantiate"
                        Pkg.instantiate()
                    elseif act == "resolve"
                        Pkg.resolve()
                    elseif act == "test"
                        if isempty(pkgs)
                            Pkg.test()
                        else
                            Pkg.test(pkgs)
                        end
                    elseif act == "develop"
                        for pkg in pkgs
                            if startswith(pkg, "/") || startswith(pkg, ".") || startswith(pkg, "~")
                                Pkg.develop(path=expanduser(pkg))
                            else
                                Pkg.develop(pkg)
                            end
                        end
                    elseif act == "free"
                        Pkg.free(pkgs)
                    end
                catch e
                    _pkg_err = sprint(showerror, e, catch_backtrace())
                end
                _pkg_err
            end))
            (error = _pkg_err, stdout = stdout_content, stderr = stderr_content)
        end
    end

    try
        return _remote_eval_fetch(worker, pkg_expr)
    catch e
        _handle_worker_crash!(session, e)
        return (error = "Pkg.$action failed — $(_crash_message(e))",
                stdout = "", stderr = "")
    end
end
