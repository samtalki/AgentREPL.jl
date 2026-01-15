# Test variables created during tests - cleaned up at end
const TEST_SYMBOLS = Symbol[]

# Helper to track test symbols for cleanup
function track_symbol(name::Symbol)
    push!(TEST_SYMBOLS, name)
end

@testset "Code Evaluation" begin
    @testset "Basic arithmetic" begin
        value, output, err, bt = AgentEval.capture_eval("1 + 1")
        @test err === nothing
        @test bt === nothing
        @test value == 2
    end

    @testset "Variable assignment" begin
        value, output, err, bt = AgentEval.capture_eval("test_var_123 = 42")
        track_symbol(:test_var_123)
        @test err === nothing
        @test value == 42

        # Variable should persist in Main
        @test Main.test_var_123 == 42
    end

    @testset "Multi-line code" begin
        code = """
        function test_multiline_func(x)
            x * 2
        end
        test_multiline_func(21)
        """
        value, output, err, bt = AgentEval.capture_eval(code)
        track_symbol(:test_multiline_func)
        @test err === nothing
        @test value == 42

        # Function should persist
        @test Main.test_multiline_func(10) == 20
    end

    @testset "Output capture" begin
        value, output, err, bt = AgentEval.capture_eval("println(\"Hello, test!\")")
        @test err === nothing
        @test contains(output, "Hello, test!")
    end

    @testset "Error handling" begin
        value, output, err, bt = AgentEval.capture_eval("undefined_variable_xyz_abc")
        @test err !== nothing
        @test bt !== nothing  # Backtrace should be captured
        # Error can be LoadError wrapping UndefVarError
        @test err isa Union{UndefVarError, LoadError}
    end

    @testset "Syntax error" begin
        value, output, err, bt = AgentEval.capture_eval("1 +")
        @test err !== nothing
    end
end

@testset "Result Formatting" begin
    @testset "Success with value" begin
        result = AgentEval.format_result(42, "", nothing, nothing)
        @test contains(result, "Result: 42")
    end

    @testset "Success with output" begin
        result = AgentEval.format_result(nothing, "Hello!", nothing, nothing)
        @test contains(result, "Output:")
        @test contains(result, "Hello!")
    end

    @testset "Error formatting with backtrace" begin
        # Create a real backtrace by catching an error
        local bt
        try
            error("Test error")
        catch e
            bt = catch_backtrace()
        end
        err = ErrorException("Test error")
        result = AgentEval.format_result(nothing, "", err, bt)
        @test contains(result, "Error:")
        @test contains(result, "Test error")
    end

    @testset "Error formatting without backtrace" begin
        err = ErrorException("Test error")
        result = AgentEval.format_result(nothing, "", err, nothing)
        @test contains(result, "Error:")
        @test contains(result, "Test error")
    end
end

@testset "User Symbols" begin
    # Create a test variable via capture_eval (which uses include_string)
    AgentEval.capture_eval("test_user_symbol_789 = 123")
    track_symbol(:test_user_symbol_789)

    symbols = AgentEval.get_user_symbols()

    # Should include our test variable
    @test :test_user_symbol_789 in symbols

    # Should not include protected symbols
    @test :Base ∉ symbols
    @test :Core ∉ symbols
    @test :Main ∉ symbols
end

@testset "Protected Symbols" begin
    # These should all be in the protected set
    @test :Base in AgentEval.PROTECTED_SYMBOLS
    @test :Core in AgentEval.PROTECTED_SYMBOLS
    @test :Main in AgentEval.PROTECTED_SYMBOLS
    @test :eval in AgentEval.PROTECTED_SYMBOLS
    @test :include in AgentEval.PROTECTED_SYMBOLS
end

# Cleanup: Clear test symbols from Main module
@testset "Cleanup" begin
    for name in TEST_SYMBOLS
        try
            Core.eval(Main, :($(name) = nothing))
        catch
            # Ignore cleanup errors
        end
    end
    @test true  # Cleanup completed
end
