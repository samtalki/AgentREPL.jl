# packages.jl - Package management and project activation

"""
    activate_project_on_worker!(path::String)

Activate a Julia project/environment on the worker.

Supports:
- Regular paths: "/path/to/project", "./relative/path"
- Current directory: "." or "@."
- Shared environments: "@v1.12", "@myenv" (expands to ~/.julia/environments/...)
"""
function activate_project_on_worker!(path::String)
    worker_id = ensure_worker!()

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
                (success = true, project = dirname(Pkg.project().path))
            catch e
                (success = false, error = sprint(showerror, e))
            end
        end
    end

    result = remotecall_fetch(Core.eval, worker_id, Main, activate_expr)

    if result.success
        WORKER.project_path = result.project
    end

    return result
end

"""
    run_pkg_action_on_worker(action::String, pkg_list::Vector{String})

Run a Pkg action on the worker process.
"""
function run_pkg_action_on_worker(action::String, pkg_list::Vector{String})
    worker_id = ensure_worker!()

    pkg_expr = quote
        let act = $action, pkgs = $pkg_list
            old_stdout = stdout
            old_stderr = stderr
            rd_out, wr_out = redirect_stdout()
            rd_err, wr_err = redirect_stderr()

            err = nothing
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
                    # develop can take paths or package names
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
                err = sprint(showerror, e, catch_backtrace())
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

            (error = err, stdout = stdout_content, stderr = stderr_content)
        end
    end

    return remotecall_fetch(Core.eval, worker_id, Main, pkg_expr)
end
