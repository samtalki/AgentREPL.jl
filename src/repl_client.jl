#!/usr/bin/env julia
# repl_client.jl - Interactive REPL client that connects to an AgentREPL worker via Unix domain socket
#
# Usage: julia repl_client.jl <socket_path> [session_name]
#
# This script connects to a Unix domain socket server running inside a Distributed.jl worker,
# providing a human-friendly REPL that shares state with the MCP agent.

using Sockets: connect
using Base64: base64decode

function main()
    if length(ARGS) < 1
        println(stderr, "Usage: julia repl_client.jl <socket_path> [session_name]")
        exit(1)
    end

    sock_path = ARGS[1]
    session_name = length(ARGS) >= 2 ? ARGS[2] : "default"

    if !ispath(sock_path)
        println(stderr, "Error: Socket not found at $sock_path")
        println(stderr, "The AgentREPL session may have been destroyed or the server restarted.")
        exit(1)
    end

    local conn
    try
        conn = connect(sock_path)
    catch e
        println(stderr, "Error: Could not connect to $sock_path")
        println(stderr, sprint(showerror, e))
        exit(1)
    end

    # Header
    printstyled("AgentREPL Interactive Session", color=:green, bold=true)
    println()
    printstyled("Session: ", color=:light_black)
    printstyled(session_name, color=:cyan)
    println()
    printstyled("Shared state with MCP agent — variables and packages are visible to both sides", color=:light_black)
    println()
    printstyled("Type 'exit' or Ctrl+D to disconnect (session continues running)", color=:light_black)
    println()
    println()

    prompt = "julia[$session_name]> "
    continuation = " "^length("julia[$session_name]") * "> "

    while isopen(conn)
        # Print prompt
        printstyled(prompt, color=:green, bold=true)

        # Read input
        line = try
            readline(stdin)
        catch e
            if e isa InterruptException
                println()
                continue
            end
            break  # EOF
        end

        # Handle exit
        if line == "exit" || line == "quit"
            break
        end

        # Skip empty lines
        if isempty(strip(line))
            continue
        end

        # Accumulate multi-line input (detect incomplete expressions)
        code = line
        while true
            try
                Meta.parse(code)
                break  # Valid expression, send it
            catch e
                if e isa Meta.ParseError && occursin("incomplete", lowercase(string(e)))
                    printstyled(continuation, color=:green)
                    next_line = try
                        readline(stdin)
                    catch
                        break
                    end
                    code *= "\n" * next_line
                else
                    break  # Syntax error — send it and let the worker report the error
                end
            end
        end

        # Send code to worker
        try
            println(conn, code)
            flush(conn)
        catch e
            printstyled("Connection lost\n", color=:red)
            break
        end

        # Read response
        response = try
            readline(conn)
        catch e
            printstyled("Connection lost\n", color=:red)
            break
        end

        if isempty(response)
            printstyled("Connection closed by server\n", color=:red)
            break
        end

        # Parse response
        if startswith(response, "OK:")
            encoded = response[4:end]
            result = String(base64decode(encoded))
            if !isempty(strip(result)) && strip(result) != "nothing"
                println(result)
            end
        elseif startswith(response, "ERR:")
            encoded = response[5:end]
            error_msg = String(base64decode(encoded))
            printstyled("ERROR: ", color=:red, bold=true)
            printstyled(error_msg, color=:red)
            println()
        else
            println(response)
        end

        println()  # Blank line between interactions
    end

    try; close(conn); catch; end
    printstyled("\nDisconnected from session '$session_name'. Session continues running.\n", color=:light_black)
end

main()
