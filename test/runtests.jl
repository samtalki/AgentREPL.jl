using Test
using AgentREPL
using Distributed
using Aqua

@testset "AgentREPL.jl" begin
    @testset "Code quality (Aqua.jl)" begin
        Aqua.test_all(AgentREPL; ambiguities=false,
            stale_deps=(; ignore=[:UnicodePlots]))  # UnicodePlots is used on workers, not in main module
    end

    include("test_highlighting.jl")
    include("test_eval.jl")
    include("test_sessions.jl")
    include("test_revise.jl")

    # MCP protocol integration tests (spawn server subprocess, ~60s)
    # Run with: AGENTREPL_E2E=true julia --project=. -e "using Pkg; Pkg.test()"
    if get(ENV, "AGENTREPL_E2E", "false") == "true"
        include("test_mcp_protocol.jl")
    end
end
