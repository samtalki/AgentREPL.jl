# attach.jl - Interactive shared REPL via Unix domain sockets

"""
    _socket_path(session_name::String) -> String

Generate the Unix domain socket path for a session's interactive REPL server.
"""
function _socket_path(session_name::String)
    joinpath(tempdir(), "agentrepl-$(session_name)-$(getpid()).sock")
end

"""
    _start_repl_socket_server!(session::SessionState)

Start a Unix domain socket server on the session's worker process.
The server listens for connections and evaluates code in Main, returning results.
Socket file is chmod 600 for security (owner-only access).

Protocol (line-based, base64-encoded):
- Client sends base64-encoded Julia code as a single line (supports multiline code)
- Server responds with: "OK:<base64-encoded result>" or "ERR:<base64-encoded error>"
- Empty line from client = disconnect

Socket cleanup relies on worker kill — no explicit server stop mechanism exists.
listen() and chmod() run synchronously before the @async accept loop, so start
failures are detected immediately by remotecall_fetch.

Note: The interactive REPL and MCP eval share the same worker process. Concurrent
evaluation from both paths may produce interleaved stdout/stderr output.
"""
function _start_repl_socket_server!(session::SessionState)
    worker_id = session.worker_id
    worker_id === nothing && error("Session '$(session.name)' has no worker. Call eval first to spawn one.")

    sock_path = _socket_path(session.name)

    # Clean up stale socket file if it exists
    ispath(sock_path) && rm(sock_path)

    server_expr = quote
        let sock_path = $sock_path
            using Sockets: listen, accept
            using Base64: base64encode, base64decode

            server = listen(sock_path)
            chmod(sock_path, 0o600)

            @async while isopen(server)
                try
                    conn = accept(server)
                    @async begin
                        try
                            while isopen(conn)
                                line = readline(conn)
                                isempty(line) && break

                                # Decode base64-encoded code from client (supports multiline)
                                code = try
                                    String(base64decode(line))
                                catch
                                    line  # fallback: treat as raw code
                                end

                                result_str = try
                                    val = include_string(Main, code, "interactive_repl")
                                    repr_str = try
                                        sprint(io -> show(IOContext(io, :color => true, :compact => true, :limit => true), MIME"text/plain"(), val))
                                    catch e
                                        e isa OutOfMemoryError && rethrow()
                                        e isa InterruptException && rethrow()
                                        try
                                            string(val)
                                        catch inner_e
                                            inner_e isa OutOfMemoryError && rethrow()
                                            inner_e isa InterruptException && rethrow()
                                            "<$(typeof(val))>"
                                        end
                                    end
                                    "OK:" * base64encode(repr_str)
                                catch e
                                    e isa OutOfMemoryError && rethrow()
                                    e isa InterruptException && rethrow()
                                    err_str = sprint(showerror, e, catch_backtrace())
                                    "ERR:" * base64encode(err_str)
                                end

                                println(conn, result_str)
                                flush(conn)
                            end
                        catch e
                            e isa OutOfMemoryError && rethrow()
                            e isa InterruptException && rethrow()
                            @debug "REPL socket connection ended" exception=e
                        finally
                            try; close(conn); catch; end
                        end
                    end
                catch e
                    e isa OutOfMemoryError && rethrow()
                    e isa InterruptException && rethrow()
                    isopen(server) && @warn "REPL socket accept error" exception=e
                end
            end

            sock_path  # return path for confirmation
        end
    end

    try
        result = remotecall_fetch(Core.eval, worker_id, Main, server_expr)
        session.socket_path = sock_path
        return sock_path
    catch e
        _handle_worker_crash!(session, e)
        error("Failed to start REPL socket server on worker: $(sprint(showerror, e))")
    end
end

"""
    _open_attach_tmux(session::SessionState) -> String

Open a tmux window with the interactive REPL client connected to the session's worker.
Returns the tmux session name for the user to attach to.
"""
function _open_attach_tmux(session::SessionState)
    sock_path = session.socket_path
    sock_path === nothing && error("No REPL socket server running for session '$(session.name)'. This is a bug.")

    tmux_name = "julia-repl-$(session.name)"
    session_name = session.name

    # Kill existing tmux session if any
    try
        run(ignorestatus(pipeline(`tmux kill-session -t $tmux_name`, devnull)))
    catch e
        @debug "tmux kill-session failed" exception=e
    end

    # Path to the repl client script
    client_script = joinpath(@__DIR__, "repl_client.jl")

    # Find the Julia executable and project
    julia_exe = joinpath(Sys.BINDIR, "julia")
    project_dir = try
        dirname(Pkg.project().path)
    catch
        @warn "Could not determine project directory for REPL client, using '.'"
        "."
    end

    # Create tmux session running the REPL client
    try
        run(`tmux new-session -d -s $tmux_name $julia_exe --project=$project_dir $client_script $sock_path $session_name`)
    catch e
        error("Failed to create tmux session: $(sprint(showerror, e)). Is tmux installed?")
    end

    # Try to open a terminal window with the tmux session
    terminal = find_terminal_emulator()
    if terminal !== nothing
        try
            if Sys.isapple()
                script = """
                tell application "Terminal"
                    activate
                    do script "tmux attach -t $tmux_name"
                end tell
                """
                run(pipeline(`osascript -e $script`, devnull))
            elseif terminal == "gnome-terminal"
                run(pipeline(`gnome-terminal -- tmux attach -t $tmux_name`, devnull); wait=false)
            elseif terminal == "konsole"
                run(pipeline(`konsole -e tmux attach -t $tmux_name`, devnull); wait=false)
            elseif terminal == "xfce4-terminal"
                run(pipeline(`xfce4-terminal -e "tmux attach -t $tmux_name"`, devnull); wait=false)
            elseif terminal == "kitty"
                run(pipeline(`kitty tmux attach -t $tmux_name`, devnull); wait=false)
            elseif terminal == "alacritty"
                run(pipeline(`alacritty -e tmux attach -t $tmux_name`, devnull); wait=false)
            elseif terminal == "xterm"
                run(pipeline(`xterm -e tmux attach -t $tmux_name`, devnull); wait=false)
            end
        catch e
            @warn "Could not open terminal window" terminal exception=e
        end
    end

    return tmux_name
end
