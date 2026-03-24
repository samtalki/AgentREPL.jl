# Test the worker subprocess model

# Helper to strip ANSI escape codes for test assertions
strip_ansi(s) = replace(s, r"\e\[[0-9;]*m" => "")

@testset "Code Evaluation" begin
    @testset "Basic arithmetic" begin
        value_str, output, error_str, elapsed = AgentREPL.capture_eval_on_worker("1 + 1")
        @test error_str === nothing
        @test value_str == "2"
    end

    @testset "Variable assignment" begin
        value_str, output, error_str, _ = AgentREPL.capture_eval_on_worker("test_var_123 = 42")
        @test error_str === nothing
        @test value_str == "42"

        # Variable should persist on worker
        value_str2, _, _, _ = AgentREPL.capture_eval_on_worker("test_var_123")
        @test value_str2 == "42"
    end

    @testset "Multi-line code" begin
        code = """
        function test_multiline_func(x)
            x * 2
        end
        test_multiline_func(21)
        """
        value_str, output, error_str, _ = AgentREPL.capture_eval_on_worker(code)
        @test error_str === nothing
        @test value_str == "42"

        # Function should persist on worker
        value_str2, _, _, _ = AgentREPL.capture_eval_on_worker("test_multiline_func(10)")
        @test value_str2 == "20"
    end

    @testset "Output capture" begin
        value_str, output, error_str, _ = AgentREPL.capture_eval_on_worker("println(\"Hello, test!\")")
        @test error_str === nothing
        @test contains(output, "Hello, test!")
    end

    @testset "Error handling" begin
        value_str, output, error_str, _ = AgentREPL.capture_eval_on_worker("undefined_variable_xyz_abc")
        @test error_str !== nothing
        @test contains(error_str, "UndefVarError")
    end

    @testset "Syntax error" begin
        value_str, output, error_str, _ = AgentREPL.capture_eval_on_worker("1 +")
        @test error_str !== nothing
    end
end

@testset "Execution Timing" begin
    @testset "Every eval returns elapsed time" begin
        _, _, _, elapsed = AgentREPL.capture_eval_on_worker("1 + 1")
        @test elapsed isa Float64
        @test elapsed >= 0.0
    end

    @testset "Timing appears in formatted result" begin
        result = AgentREPL.format_result("1 + 1", "2", "", nothing; elapsed=0.0234)
        @test contains(result, "[23.4ms]")

        result2 = AgentREPL.format_result("1 + 1", "2", "", nothing; elapsed=2.567)
        @test contains(result2, "[2.57s]")
    end

    @testset "format_elapsed helper" begin
        @test AgentREPL.format_elapsed(0.001) == "[1.0ms]"
        @test AgentREPL.format_elapsed(0.5) == "[500.0ms]"
        @test AgentREPL.format_elapsed(1.0) == "[1.0s]"
        @test AgentREPL.format_elapsed(10.5) == "[10.5s]"
    end
end

@testset "Eval Timeout" begin
    @testset "Timeout kills worker and returns TimeoutError" begin
        # sleep(10) with a 1s timeout should trigger timeout
        value_str, output, error_str, elapsed = AgentREPL.capture_eval_on_worker("sleep(10)"; timeout=1.0)
        @test error_str !== nothing
        @test contains(error_str, "TimeoutError")
        @test contains(error_str, "1.0s")
        @test elapsed >= 1.0
        # Worker should have been killed
        session = AgentREPL.get_current_session!()
        @test session.worker_id === nothing
    end

    @testset "Next eval after timeout spawns fresh worker" begin
        # After the timeout above killed the worker, a new eval should work
        value_str, output, error_str, _ = AgentREPL.capture_eval_on_worker("42")
        @test error_str === nothing
        @test value_str == "42"
        session = AgentREPL.get_current_session!()
        @test session.worker_id !== nothing
    end

    @testset "No timeout when code completes fast" begin
        value_str, output, error_str, elapsed = AgentREPL.capture_eval_on_worker("1 + 1"; timeout=10.0)
        @test error_str === nothing
        @test value_str == "2"
        @test elapsed < 10.0
    end
end

@testset "Output Truncation" begin
    @testset "Short output not truncated" begin
        text = "hello world"
        @test AgentREPL.truncate_output(text, 50_000) == text
    end

    @testset "Long output is truncated with marker" begin
        text = repeat("x", 100_000)
        result = AgentREPL.truncate_output(text, 1000)
        @test length(result) < 100_000
        @test contains(result, "characters truncated")
        # Head should start with x's
        @test startswith(result, "x")
        # Tail should end with x's
        @test endswith(result, "x")
    end

    @testset "Truncation in format_result" begin
        big_value = repeat("a", 100_000)
        result = AgentREPL.format_result("code", big_value, "", nothing; max_output=1000)
        @test length(result) < 100_000
        @test contains(result, "characters truncated")
    end

    @testset "Output and value both truncated" begin
        big_output = repeat("b", 100_000)
        big_value = repeat("c", 100_000)
        result = AgentREPL.format_result("code", big_value, big_output, nothing; max_output=2000)
        @test length(result) < 200_000
        @test contains(result, "characters truncated")
    end
end

@testset "Result Formatting" begin
    @testset "Success with value" begin
        result = AgentREPL.format_result("1 + 1", "2", "", nothing)
        @test contains(strip_ansi(result), "julia> 1 + 1")  # REPL-style prompt
        @test contains(result, "2")  # Result value
    end

    @testset "Success with output" begin
        result = AgentREPL.format_result("println(\"Hello!\")", "nothing", "Hello!", nothing)
        @test contains(result, "julia> ")
        @test contains(result, "Hello!")  # Output shown before result
    end

    @testset "Error formatting" begin
        result = AgentREPL.format_result("bad_code", "nothing", "", "UndefVarError: `bad_code` not defined")
        @test contains(strip_ansi(result), "julia> bad_code")  # Code shown with prompt
        @test contains(result, "UndefVarError")
    end

    @testset "Stacktrace truncation" begin
        long_error = """
LoadError: UndefVarError: `foo` not defined
Stacktrace:
  [1] frame1()
    @ Main ./file.jl:1
  [2] frame2()
    @ Main ./file.jl:2
  [3] frame3()
    @ Main ./file.jl:3
  [4] frame4()
    @ Main ./file.jl:4
  [5] frame5()
    @ Main ./file.jl:5
  [6] frame6()
    @ Main ./file.jl:6
  [7] frame7()
    @ Main ./file.jl:7
"""
        truncated = AgentREPL.truncate_stacktrace(long_error; max_frames=3)
        @test contains(truncated, "frame1")
        @test contains(truncated, "frame3")
        @test !contains(truncated, "frame7")
        @test contains(truncated, "truncated")
    end

    @testset "Configurable stacktrace depth" begin
        long_error = """
UndefVarError: `x` not defined
Stacktrace:
  [1] frame1()
    @ Main ./file.jl:1
  [2] frame2()
    @ Main ./file.jl:2
  [3] frame3()
    @ Main ./file.jl:3
  [4] frame4()
    @ Main ./file.jl:4
  [5] frame5()
    @ Main ./file.jl:5
"""
        # max_stackframes=2 should only show first 2 frames
        result = AgentREPL.format_result("x", "nothing", "", long_error; max_stackframes=2)
        @test contains(result, "frame1")
        @test contains(result, "frame2")
        @test !contains(result, "frame5")
        @test contains(result, "truncated")

        # max_stackframes=10 should show all frames (no truncation)
        result_all = AgentREPL.format_result("x", "nothing", "", long_error; max_stackframes=10)
        @test contains(result_all, "frame5")
        @test !contains(result_all, "truncated")
    end
end

@testset "Worker Info" begin
    # Create test variables of different types
    AgentREPL.capture_eval_on_worker("test_user_symbol_789 = 123")
    AgentREPL.capture_eval_on_worker("test_vec_abc = [1.0, 2.0, 3.0]")

    session = AgentREPL.get_current_session!()
    info = AgentREPL.get_worker_info(session)

    # Should have expected fields
    @test haskey(info, :version)
    @test haskey(info, :project)
    @test haskey(info, :variables)
    @test haskey(info, :modules)

    # Variables should be NamedTuples with name, type, size
    var_names = [v.name for v in info.variables]
    @test :test_user_symbol_789 in var_names
    @test :test_vec_abc in var_names

    # Check type info
    int_var = first(v for v in info.variables if v.name == :test_user_symbol_789)
    @test int_var.type == "Int64"

    vec_var = first(v for v in info.variables if v.name == :test_vec_abc)
    @test contains(vec_var.type, "Vector") || contains(vec_var.type, "Array")
    @test contains(vec_var.size, "3")

    # Should not include protected symbols
    @test :Base ∉ var_names
    @test :Core ∉ var_names
    @test :Main ∉ var_names
end

@testset "Worker Lifecycle" begin
    @testset "Worker reset clears state" begin
        # Set a variable
        AgentREPL.capture_eval_on_worker("reset_test_var = 999")
        value_str, _, _, _ = AgentREPL.capture_eval_on_worker("reset_test_var")
        @test value_str == "999"

        # Reset the worker
        session = AgentREPL.get_current_session!()
        old_id = session.worker_id
        new_id = AgentREPL.reset_worker!(session)
        @test new_id != old_id

        # Variable should no longer exist
        _, _, error_str, _ = AgentREPL.capture_eval_on_worker("reset_test_var")
        @test error_str !== nothing
        @test contains(error_str, "UndefVarError")
    end

    @testset "Worker persists project path on reset" begin
        # Get current project path
        session = AgentREPL.get_current_session!()
        info_before = AgentREPL.get_worker_info(session)
        project_before = info_before.project

        # Reset
        AgentREPL.reset_worker!(session)

        # Project should be reactivated
        info_after = AgentREPL.get_worker_info(session)
        @test info_after.project == project_before
    end
end

@testset "Worker Crash Recovery" begin
    @testset "exit() triggers crash recovery" begin
        # Ensure we have a worker
        session = AgentREPL.get_current_session!()
        AgentREPL.ensure_worker!(session)
        @test session.worker_id !== nothing

        # exit() should crash the worker
        value_str, output, error_str, elapsed = AgentREPL.capture_eval_on_worker("exit()")
        @test error_str !== nothing
        @test contains(error_str, "crashed") || contains(error_str, "ProcessExitedException")
        @test session.worker_id === nothing
        @test session.revise_loaded == false
    end

    @testset "Eval succeeds after crash" begin
        # Next eval should auto-spawn a fresh worker
        value_str, output, error_str, _ = AgentREPL.capture_eval_on_worker("42")
        @test error_str === nothing
        @test value_str == "42"
        session = AgentREPL.get_current_session!()
        @test session.worker_id !== nothing
    end
end

@testset "Project Activation" begin
    @testset "Activate current directory" begin
        result = AgentREPL.activate_project_on_worker!(".")
        @test result.success == true
        @test result.project isa String
    end

    @testset "Activate nonexistent path" begin
        result = AgentREPL.activate_project_on_worker!("/nonexistent/project/path")
        # Pkg.activate with a nonexistent path may create a new env or error depending on Julia version
        # Either way it should not throw
        @test result isa NamedTuple
    end

    @testset "Session project_path updated on success" begin
        session = AgentREPL.get_current_session!()
        result = AgentREPL.activate_project_on_worker!(".")
        if result.success
            @test session.project_path == result.project
        end
    end
end

@testset "Project Path Persistence" begin
    @testset "Project path survives failed reactivation" begin
        session = AgentREPL.get_current_session!()
        AgentREPL.ensure_worker!(session)
        session.project_path = "/nonexistent/project/path"
        AgentREPL.reset_worker!(session)
        @test session.project_path == "/nonexistent/project/path"
        # Clean up: restore to nil so subsequent tests aren't affected
        session.project_path = nothing
    end
end

@testset "Worker Cleanup" begin
    @testset "Cleanup function kills workers" begin
        AgentREPL.create_session!("cleanup-test")
        AgentREPL.capture_eval_on_worker("1+1"; session_name="cleanup-test")
        session = AgentREPL.SESSIONS.sessions["cleanup-test"]
        worker_id = session.worker_id
        @test worker_id !== nothing
        @test worker_id in Distributed.workers()

        AgentREPL._cleanup_all_workers!()

        @test !(worker_id in Distributed.workers())
        # Clean up session registry
        try; AgentREPL.destroy_session!("cleanup-test"); catch; end
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
    session = AgentREPL.get_current_session!()
    AgentREPL.kill_worker!(session)
    @test session.worker_id === nothing
end
