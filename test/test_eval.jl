# Test the worker subprocess model

@testset "Code Evaluation" begin
    @testset "Basic arithmetic" begin
        value_str, output, error_str = AgentREPL.capture_eval_on_worker("1 + 1")
        @test error_str === nothing
        @test value_str == "2"
    end

    @testset "Variable assignment" begin
        value_str, output, error_str = AgentREPL.capture_eval_on_worker("test_var_123 = 42")
        @test error_str === nothing
        @test value_str == "42"

        # Variable should persist on worker
        value_str2, _, _ = AgentREPL.capture_eval_on_worker("test_var_123")
        @test value_str2 == "42"
    end

    @testset "Multi-line code" begin
        code = """
        function test_multiline_func(x)
            x * 2
        end
        test_multiline_func(21)
        """
        value_str, output, error_str = AgentREPL.capture_eval_on_worker(code)
        @test error_str === nothing
        @test value_str == "42"

        # Function should persist on worker
        value_str2, _, _ = AgentREPL.capture_eval_on_worker("test_multiline_func(10)")
        @test value_str2 == "20"
    end

    @testset "Output capture" begin
        value_str, output, error_str = AgentREPL.capture_eval_on_worker("println(\"Hello, test!\")")
        @test error_str === nothing
        @test contains(output, "Hello, test!")
    end

    @testset "Error handling" begin
        value_str, output, error_str = AgentREPL.capture_eval_on_worker("undefined_variable_xyz_abc")
        @test error_str !== nothing
        @test contains(error_str, "UndefVarError")
    end

    @testset "Syntax error" begin
        value_str, output, error_str = AgentREPL.capture_eval_on_worker("1 +")
        @test error_str !== nothing
    end
end

@testset "Result Formatting" begin
    @testset "Success with value" begin
        result = AgentREPL.format_result("1 + 1", "42", "", nothing)
        @test contains(result, "Code:")
        @test contains(result, "1 + 1")
        @test contains(result, "Result: 42")
    end

    @testset "Success with output" begin
        result = AgentREPL.format_result("println(\"Hello!\")", "nothing", "Hello!", nothing)
        @test contains(result, "Code:")
        @test contains(result, "Output:")
        @test contains(result, "Hello!")
    end

    @testset "Error formatting" begin
        result = AgentREPL.format_result("bad_code()", "nothing", "", "UndefVarError: `bad_code` not defined")
        @test contains(result, "Code:")
        @test contains(result, "Error:")
        @test contains(result, "bad_code")
    end
end

@testset "Worker Info" begin
    # Create a test variable
    AgentREPL.capture_eval_on_worker("test_user_symbol_789 = 123")

    info = AgentREPL.get_worker_info()

    # Should have expected fields
    @test haskey(info, :version)
    @test haskey(info, :project)
    @test haskey(info, :variables)
    @test haskey(info, :modules)

    # Should include our test variable
    @test :test_user_symbol_789 in info.variables

    # Should not include protected symbols
    @test :Base ∉ info.variables
    @test :Core ∉ info.variables
    @test :Main ∉ info.variables
end

@testset "Worker Lifecycle" begin
    @testset "Worker reset clears state" begin
        # Set a variable
        AgentREPL.capture_eval_on_worker("reset_test_var = 999")
        value_str, _, _ = AgentREPL.capture_eval_on_worker("reset_test_var")
        @test value_str == "999"

        # Reset the worker
        old_id = AgentREPL.WORKER.worker_id
        new_id = AgentREPL.reset_worker!()
        @test new_id != old_id

        # Variable should no longer exist
        _, _, error_str = AgentREPL.capture_eval_on_worker("reset_test_var")
        @test error_str !== nothing
        @test contains(error_str, "UndefVarError")
    end

    @testset "Worker persists project path on reset" begin
        # Get current project path
        info_before = AgentREPL.get_worker_info()
        project_before = info_before.project

        # Reset
        AgentREPL.reset_worker!()

        # Project should be reactivated
        info_after = AgentREPL.get_worker_info()
        @test info_after.project == project_before
    end
end

@testset "Package Actions" begin
    @testset "Status action works" begin
        result = AgentREPL.run_pkg_action_on_worker("status", String[])
        @test result.error === nothing
        # Status should produce some output
        @test !isempty(result.stdout) || !isempty(result.stderr)
    end

    @testset "Invalid action is handled by tool (not run_pkg)" begin
        # run_pkg_action_on_worker doesn't validate actions - that's done in the tool handler
        # So we just test that valid actions don't error
        result = AgentREPL.run_pkg_action_on_worker("resolve", String[])
        @test result.error === nothing
    end

    @testset "Test action with no packages" begin
        # Running test with no packages on the current project
        # This may fail if tests don't exist, but should not throw
        result = AgentREPL.run_pkg_action_on_worker("test", String[])
        # Either succeeds or returns error in the result (not thrown)
        @test result isa NamedTuple
    end

    @testset "Develop action requires valid path" begin
        # Trying to develop a non-existent path should return an error
        result = AgentREPL.run_pkg_action_on_worker("develop", ["/nonexistent/path/to/package"])
        @test result.error !== nothing
    end

    @testset "Free action requires developed package" begin
        # Trying to free a package that's not developed should error
        result = AgentREPL.run_pkg_action_on_worker("free", ["NonExistentPackage12345"])
        @test result.error !== nothing
    end
end

# Cleanup: Kill worker at end of tests
@testset "Cleanup" begin
    AgentREPL.kill_worker!()
    @test AgentREPL.WORKER.worker_id === nothing
end
