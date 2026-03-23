using Test
using AgentREPL
using Distributed

@testset "AgentREPL.jl" begin
    include("test_highlighting.jl")
    include("test_eval.jl")
    include("test_sessions.jl")
end
