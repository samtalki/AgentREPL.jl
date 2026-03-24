# test_mcp_protocol.jl - End-to-end MCP protocol integration tests
#
# Spawns the AgentREPL MCP server as a subprocess (exactly as Claude Code does)
# and communicates via JSON-RPC over stdin/stdout.
#
# Run with: AGENTREPL_E2E=true julia --project=. test/test_mcp_protocol.jl
#
# These tests take ~60s due to Julia startup and worker spawning.

using Test
using JSON3

const PROJECT_DIR = dirname(@__DIR__)
const SERVER_SCRIPT = joinpath(PROJECT_DIR, "bin", "julia-repl-server")
const JULIA_EXE = Base.julia_cmd().exec[1]

# --- JSON-RPC helpers ---

mutable struct MCPClient
    proc::Base.Process
    input::IO   # write to server stdin
    output::IO  # read from server stdout
    next_id::Int
end

function start_server()
    cmd = `$JULIA_EXE --project=$PROJECT_DIR $SERVER_SCRIPT`
    proc = open(cmd, "r+")
    MCPClient(proc, proc, proc, 1)
end

function send_request!(client::MCPClient, method::String, params::Dict=Dict())
    id = client.next_id
    client.next_id += 1
    msg = JSON3.write(Dict(
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => params
    ))
    write(client.input, msg * "\n")
    flush(client.input)
    return id
end

function send_notification!(client::MCPClient, method::String, params::Dict=Dict())
    msg = JSON3.write(Dict(
        "jsonrpc" => "2.0",
        "method" => method,
        "params" => params
    ))
    write(client.input, msg * "\n")
    flush(client.input)
end

function recv_response(client::MCPClient; timeout::Float64=60.0)
    deadline = time() + timeout
    while true
        remaining = deadline - time()
        remaining <= 0 && error("Timeout ($(timeout)s) reading from MCP server")

        ch = Channel{String}(1)
        @async begin
            try
                line = readline(client.output)
                put!(ch, line)
            catch e
                try; put!(ch, ""); catch; end
            end
        end
        timer = Timer(remaining) do _
            try; put!(ch, ""); catch; end
        end
        line = take!(ch)
        close(timer)
        close(ch)

        isempty(line) && error("Timeout ($(timeout)s) or EOF reading from MCP server")

        # Skip non-JSON lines (e.g., "From worker N:" messages from Distributed.jl)
        stripped = strip(line)
        if startswith(stripped, "{")
            return JSON3.read(line, Dict{String,Any})
        end
        # else: skip this line and read the next one
    end
end

function call_tool!(client::MCPClient, name::String, arguments::Dict=Dict(); timeout::Float64=60.0)
    send_request!(client, "tools/call", Dict("name" => name, "arguments" => arguments))
    resp = recv_response(client; timeout=timeout)
    return resp
end

function get_tool_text(resp)
    result = resp["result"]
    content = result["content"]
    return content[1]["text"]
end

function shutdown!(client::MCPClient)
    try
        close(client.input)
    catch; end
    try
        wait(client.proc)
    catch; end
end

# --- Tests ---

@testset "MCP Protocol Integration" begin
    client = start_server()

    try
        # --- Initialize handshake ---
        @testset "Initialize handshake" begin
            send_request!(client, "initialize", Dict(
                "capabilities" => Dict(),
                "clientInfo" => Dict("name" => "test-client", "version" => "1.0"),
                "protocolVersion" => "2025-06-18"
            ))
            resp = recv_response(client; timeout=30.0)
            @test haskey(resp, "result")
            @test resp["result"]["serverInfo"]["name"] == "julia-repl"
            @test haskey(resp["result"], "protocolVersion")

            # Send initialized notification
            send_notification!(client, "notifications/initialized")
        end

        # --- List tools ---
        @testset "List tools" begin
            send_request!(client, "tools/list", Dict())
            resp = recv_response(client; timeout=10.0)
            tool_names = Set([t["name"] for t in resp["result"]["tools"]])
            expected = Set(["eval", "reset", "info", "pkg", "activate", "log_viewer", "session", "revise"])
            @test tool_names == expected
        end

        # --- eval tool ---
        @testset "eval - basic arithmetic" begin
            resp = call_tool!(client, "eval", Dict("code" => "1 + 1"); timeout=90.0)
            text = get_tool_text(resp)
            @test occursin("2", text)
        end

        @testset "eval - variable persistence" begin
            call_tool!(client, "eval", Dict("code" => "_test_x = 42"); timeout=30.0)
            resp = call_tool!(client, "eval", Dict("code" => "_test_x"); timeout=30.0)
            text = get_tool_text(resp)
            @test occursin("42", text)
        end

        @testset "eval - error handling" begin
            resp = call_tool!(client, "eval", Dict("code" => "undefined_var_xyz"); timeout=30.0)
            text = get_tool_text(resp)
            @test occursin("UndefVarError", text)
        end

        @testset "eval - output capture" begin
            resp = call_tool!(client, "eval", Dict("code" => "println(\"hello_mcp\"); 99"); timeout=30.0)
            text = get_tool_text(resp)
            @test occursin("hello_mcp", text)
            @test occursin("99", text)
        end

        # --- info tool ---
        @testset "info" begin
            resp = call_tool!(client, "info", Dict(); timeout=30.0)
            text = get_tool_text(resp)
            @test occursin("Julia Version", text)
            @test occursin("default", text)  # session name
        end

        # --- session tool ---
        @testset "session - create" begin
            resp = call_tool!(client, "session", Dict("action" => "create", "name" => "test-s1"); timeout=10.0)
            text = get_tool_text(resp)
            @test occursin("test-s1", text)
            @test occursin("created", text)
        end

        @testset "session - list" begin
            resp = call_tool!(client, "session", Dict("action" => "list"); timeout=10.0)
            text = get_tool_text(resp)
            @test occursin("test-s1", text)
            @test occursin("default", text)
        end

        @testset "session - isolation" begin
            # Set a variable in default session
            call_tool!(client, "session", Dict("action" => "switch", "name" => "default"); timeout=10.0)
            call_tool!(client, "eval", Dict("code" => "_isolation_var = 999"); timeout=30.0)

            # Switch to test-s1 and try to access it
            call_tool!(client, "session", Dict("action" => "switch", "name" => "test-s1"); timeout=10.0)
            resp = call_tool!(client, "eval", Dict("code" => "_isolation_var"); timeout=90.0)
            text = get_tool_text(resp)
            @test occursin("UndefVarError", text)

            # Switch back
            call_tool!(client, "session", Dict("action" => "switch", "name" => "default"); timeout=10.0)
        end

        @testset "session - destroy" begin
            resp = call_tool!(client, "session", Dict("action" => "destroy", "name" => "test-s1"); timeout=10.0)
            text = get_tool_text(resp)
            @test occursin("destroyed", text)
        end

        # --- pkg tool ---
        @testset "pkg - status" begin
            resp = call_tool!(client, "pkg", Dict("action" => "status"); timeout=30.0)
            text = get_tool_text(resp)
            @test occursin("Status", text) || occursin("status", text) || occursin("Package", text)
        end

        # --- activate tool ---
        @testset "activate" begin
            resp = call_tool!(client, "activate", Dict("path" => "."); timeout=30.0)
            text = get_tool_text(resp)
            @test occursin("Activated", text) || occursin("activated", text) || occursin("project", text)
        end

        # --- revise tool ---
        @testset "revise - status" begin
            resp = call_tool!(client, "revise", Dict("action" => "status"); timeout=30.0)
            text = get_tool_text(resp)
            @test occursin("Revise", text) || occursin("revise", text)
        end

        # --- log_viewer tool ---
        # Skip log_viewer tests: mode="file" and mode="auto" open terminal windows
        # which have visual side effects inappropriate for automated testing.
        # The log_viewer tool is tested manually.

        # --- reset tool (run last since it kills the worker) ---
        @testset "reset" begin
            # First set a variable
            call_tool!(client, "eval", Dict("code" => "_reset_var = 123"); timeout=30.0)

            # Reset
            resp = call_tool!(client, "reset", Dict(); timeout=60.0)
            text = get_tool_text(resp)
            @test occursin("reset", lowercase(text))

            # Verify variable is gone
            resp = call_tool!(client, "eval", Dict("code" => "_reset_var"); timeout=90.0)
            text = get_tool_text(resp)
            @test occursin("UndefVarError", text)
        end

    finally
        shutdown!(client)
    end
end
