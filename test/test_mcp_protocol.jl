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
    input::IO                 # write to server stdin
    output::IO                # read from server stdout
    next_id::Int
    lines::Channel{String}    # every stdout line, fed by one background reader
    errlines::Channel{String} # every stderr line (server logs + drained worker output)
end

# One reader per stream owns it. Consumers poll the channels; nothing else calls
# readline, so no dangling reader can steal another consumer's line.
function _spawn_reader(io, ch)
    @async begin
        try
            for line in eachline(io)
                put!(ch, line)
            end
        catch
        finally
            try; close(ch); catch; end
        end
    end
end

function start_server()
    cmd = `$JULIA_EXE --project=$PROJECT_DIR $SERVER_SCRIPT`
    # Explicit pipes (not `open(cmd, "r+")`) so we can capture stderr separately and
    # verify worker output is routed there rather than onto the stdout transport.
    inp = Pipe(); outp = Pipe(); errp = Pipe()
    proc = run(pipeline(cmd; stdin=inp, stdout=outp, stderr=errp); wait=false)
    close(inp.out); close(outp.in); close(errp.in)
    lines = Channel{String}(10_000)
    # Large cap: the server's stderr accumulates across the whole session; it must not
    # fill and block the reader before a later test drains it.
    errlines = Channel{String}(200_000)
    client = MCPClient(proc, inp, outp, 1, lines, errlines)
    _spawn_reader(outp, lines)
    _spawn_reader(errp, errlines)
    return client
end

# Take the next line from the reader channel within `timeout`, or `nothing`.
# Polls with `isready` so it never leaves a blocked `take!` behind.
function _next_line(client::MCPClient, timeout::Float64)
    deadline = time() + timeout
    while time() < deadline
        if isready(client.lines)
            return take!(client.lines)
        elseif !isopen(client.lines)
            return nothing  # reader finished (server EOF) and nothing buffered
        end
        sleep(0.02)
    end
    return nothing
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

function recv_response(client::MCPClient; timeout::Float64=60.0, id::Union{Int,Nothing}=nothing)
    deadline = time() + timeout
    while true
        remaining = deadline - time()
        remaining <= 0 && error("Timeout ($(timeout)s) waiting for response id=$(id)")

        line = _next_line(client, remaining)
        line === nothing && error("Timeout ($(timeout)s) or EOF waiting for response id=$(id)")

        # Skip any non-JSON line (defensive — the transport should be clean JSON).
        startswith(strip(line), "{") || continue
        msg = JSON3.read(line, Dict{String,Any})
        # When an id is given, skip notifications and responses for other requests.
        # This keeps one slow call (whose response arrives after its timeout) from
        # desyncing the stream and poisoning every later call.
        if id !== nothing
            (haskey(msg, "id") && msg["id"] == id) || continue
        end
        return msg
    end
end

function call_tool!(client::MCPClient, name::String, arguments::Dict=Dict(); timeout::Float64=60.0)
    id = send_request!(client, "tools/call", Dict("name" => name, "arguments" => arguments))
    return recv_response(client; timeout=timeout, id=id)
end

function get_tool_text(resp)
    result = resp["result"]
    content = result["content"]
    return content[1]["text"]
end

# Collect everything the server emits on stdout over `idle` seconds. Used to assert
# the JSON-RPC transport never carries stray (non-JSON) output.
function drain_stdout_lines(client::MCPClient; idle::Float64=3.0)
    return _drain(client.lines; idle=idle)
end

# Collect the server's stderr (its own logs plus worker output drained to stderr)
# over `idle` seconds. Used to prove worker out-of-band output lands on stderr.
function drain_stderr_lines(client::MCPClient; idle::Float64=3.0)
    return _drain(client.errlines; idle=idle)
end

function _drain(ch::Channel{String}; idle::Float64=3.0)
    lines = String[]
    deadline = time() + idle
    while time() < deadline
        if isready(ch)
            line = take!(ch)
            isempty(line) || push!(lines, line)
        else
            sleep(0.05)
        end
    end
    return lines
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
            id = send_request!(client, "initialize", Dict(
                "capabilities" => Dict(),
                "clientInfo" => Dict("name" => "test-client", "version" => "1.0"),
                "protocolVersion" => "2025-06-18"
            ))
            # Generous: the server subprocess cold-starts (loads the package + deps)
            # before it can answer, which is slow on CI runners.
            resp = recv_response(client; timeout=180.0, id=id)
            @test haskey(resp, "result")
            @test resp["result"]["serverInfo"]["name"] == "julia-repl"
            @test haskey(resp["result"], "protocolVersion")

            # Advertise only what we implement: tools + resources, not prompts (B1)
            caps = resp["result"]["capabilities"]
            @test haskey(caps, "tools")
            @test haskey(caps, "resources")
            @test !haskey(caps, "prompts")

            # Send initialized notification
            send_notification!(client, "notifications/initialized")
        end

        # --- List tools ---
        @testset "List tools" begin
            id = send_request!(client, "tools/list", Dict())
            resp = recv_response(client; timeout=30.0, id=id)
            tools = resp["result"]["tools"]
            tool_names = Set([t["name"] for t in tools])
            expected = Set(["eval", "reset", "info", "pkg", "activate", "log_viewer", "session", "revise"])
            @test tool_names == expected
            # Every tool carries a human-friendly title (B3)
            @test all(haskey(t, "title") && !isempty(t["title"]) for t in tools)
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

        # --- resources ---
        @testset "resources - list" begin
            id = send_request!(client, "resources/list", Dict())
            resp = recv_response(client; timeout=30.0, id=id)
            uris = Set([r["uri"] for r in resp["result"]["resources"]])
            @test "agentrepl://session/info" in uris
            @test "agentrepl://session/variables" in uris
            @test "agentrepl://sessions" in uris
        end

        @testset "resources - read info" begin
            id = send_request!(client, "resources/read", Dict("uri" => "agentrepl://session/info"))
            resp = recv_response(client; timeout=60.0, id=id)
            contents = resp["result"]["contents"]
            @test !isempty(contents)
            payload = JSON3.read(contents[1]["text"], Dict{String,Any})
            @test haskey(payload, "julia_version")
            @test haskey(payload, "worker_pid")
        end

        # --- transport stays clean JSON even when a worker prints out of band ---
        @testset "Transport stream cleanliness" begin
            # marker bytes "{LEAK" — built at runtime, so it cannot appear in the
            # echoed source. It fires ~1s later, outside the eval capture window.
            code = "@async (sleep(1.0); println(String(UInt8[123,76,69,65,75]))); 7"
            resp = call_tool!(client, "eval", Dict("code" => code); timeout=90.0)
            @test occursin("7", get_tool_text(resp))

            extra = drain_stdout_lines(client; idle=3.0)  # window for the async print
            for line in extra
                @test startswith(strip(line), "{")              # never raw worker output
                @test JSON3.read(line, Dict{String,Any}) isa Dict  # every line is valid JSON-RPC
            end
            @test !any(l -> occursin("LEAK", l), extra)         # marker never hit the transport

            # The marker MUST instead surface on the server's stderr. This proves the
            # drain actually ran and routed worker output away from the transport —
            # not merely that Malt's monitor flags are off. Without this assertion the
            # stdout check could pass even if draining were broken.
            errs = drain_stderr_lines(client; idle=3.0)
            @test any(l -> occursin("{LEAK", l), errs)

            # transport still intact afterwards
            resp2 = call_tool!(client, "eval", Dict("code" => "2+2"); timeout=30.0)
            @test occursin("4", get_tool_text(resp2))
        end

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
