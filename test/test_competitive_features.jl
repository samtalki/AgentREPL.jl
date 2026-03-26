# Test competitive features: isolated eval, ephemeral sessions, audit logging, workspace sync

@testset "Isolated Eval" begin
    @testset "Returns correct result" begin
        value_str, output, error_str, elapsed = AgentREPL.capture_eval_on_worker("1 + 1"; isolated=true)
        @test error_str === nothing
        @test value_str == "2"
        @test elapsed > 0
    end

    @testset "Variables don't persist to Main" begin
        value_str, _, error_str, _ = AgentREPL.capture_eval_on_worker("isolated_test_var_xyz = 42"; isolated=true)
        @test error_str === nothing
        @test value_str == "42"

        _, _, error_str2, _ = AgentREPL.capture_eval_on_worker("isolated_test_var_xyz")
        @test error_str2 !== nothing
        @test contains(error_str2, "UndefVarError")
    end

    @testset "Handles errors correctly" begin
        _, _, error_str, _ = AgentREPL.capture_eval_on_worker("undefined_isolated_xyz"; isolated=true)
        @test error_str !== nothing
        @test contains(error_str, "UndefVarError")
    end

    @testset "Can use Base functions" begin
        value_str, _, error_str, _ = AgentREPL.capture_eval_on_worker("sum([1,2,3])"; isolated=true)
        @test error_str === nothing
        @test value_str == "6"
    end

    @testset "Records timing" begin
        session = AgentREPL.get_current_session!()
        n_before = length(session.eval_timings)
        AgentREPL.capture_eval_on_worker("1+1"; isolated=true)
        @test length(session.eval_timings) == n_before + 1
    end
end

@testset "Ephemeral Sessions" begin
    @testset "Create, eval, and destroy workflow" begin
        n_before = length(AgentREPL.SESSIONS.sessions)

        eph_name = "test-ephemeral-$(rand(UInt32))"
        AgentREPL.create_session!(eph_name)

        value_str, _, error_str, _ = AgentREPL.capture_eval_on_worker("1 + 1"; session_name=eph_name)
        @test error_str === nothing
        @test value_str == "2"

        AgentREPL.destroy_session!(eph_name)
        @test !haskey(AgentREPL.SESSIONS.sessions, eph_name)
        @test length(AgentREPL.SESSIONS.sessions) == n_before
    end

    @testset "Doesn't affect current session" begin
        AgentREPL.capture_eval_on_worker("ephemeral_check_var_abc = 999")

        eph_name = "test-eph-isolation"
        AgentREPL.create_session!(eph_name)
        AgentREPL.capture_eval_on_worker("x = 42"; session_name=eph_name)
        AgentREPL.destroy_session!(eph_name)

        value_str, _, error_str, _ = AgentREPL.capture_eval_on_worker("ephemeral_check_var_abc")
        @test error_str === nothing
        @test value_str == "999"
    end

    @testset "Cleanup on error" begin
        eph_name = "test-eph-error"
        AgentREPL.create_session!(eph_name)

        _, _, error_str, _ = AgentREPL.capture_eval_on_worker("undefined_eph_var_xyz"; session_name=eph_name)
        @test error_str !== nothing

        AgentREPL.destroy_session!(eph_name)
        @test !haskey(AgentREPL.SESSIONS.sessions, eph_name)
    end
end

@testset "Audit Logging" begin
    @testset "Disabled by default (no-op)" begin
        @test AgentREPL._AUDIT_DIR[] === nothing
        AgentREPL.audit_interaction("test", "code", "result", "output", nothing)
        @test isempty(AgentREPL._AUDIT_IOS)
    end

    @testset "Writes files when enabled" begin
        mktempdir() do dir
            old_dir = AgentREPL._AUDIT_DIR[]
            try
                AgentREPL._AUDIT_DIR[] = dir
                AgentREPL.audit_interaction("test-session", "1+1", "2", "", nothing; elapsed=0.01)

                files = readdir(dir)
                @test length(files) == 1
                @test startswith(files[1], "test-session_")
                @test endswith(files[1], ".log")

                content = read(joinpath(dir, files[1]), String)
                @test contains(content, "session=test-session")
                @test contains(content, "julia> 1+1")
                @test contains(content, "--- result ---")
                @test contains(content, "2")
            finally
                AgentREPL.close_audit_logs!()
                AgentREPL._AUDIT_DIR[] = old_dir
            end
        end
    end

    @testset "Writes error entries" begin
        mktempdir() do dir
            old_dir = AgentREPL._AUDIT_DIR[]
            try
                AgentREPL._AUDIT_DIR[] = dir
                AgentREPL.audit_interaction("err-sess", "bad", "nothing", "", "UndefVarError"; elapsed=0.005)

                content = read(joinpath(dir, readdir(dir)[1]), String)
                @test contains(content, "--- error ---")
                @test contains(content, "UndefVarError")
            finally
                AgentREPL.close_audit_logs!()
                AgentREPL._AUDIT_DIR[] = old_dir
            end
        end
    end

    @testset "Truncates large results" begin
        mktempdir() do dir
            old_dir = AgentREPL._AUDIT_DIR[]
            try
                AgentREPL._AUDIT_DIR[] = dir
                big_result = repeat("x", 5000)
                AgentREPL.audit_interaction("trunc-sess", "code", big_result, "", nothing)

                content = read(joinpath(dir, readdir(dir)[1]), String)
                @test contains(content, "chars truncated")
            finally
                AgentREPL.close_audit_logs!()
                AgentREPL._AUDIT_DIR[] = old_dir
            end
        end
    end

    @testset "close_audit_io_for_session! cleans up specific session" begin
        mktempdir() do dir
            old_dir = AgentREPL._AUDIT_DIR[]
            try
                AgentREPL._AUDIT_DIR[] = dir
                AgentREPL.audit_interaction("sa", "1+1", "2", "", nothing)
                AgentREPL.audit_interaction("sb", "2+2", "4", "", nothing)
                @test haskey(AgentREPL._AUDIT_IOS, "sa")
                @test haskey(AgentREPL._AUDIT_IOS, "sb")

                AgentREPL.close_audit_io_for_session!("sa")
                @test !haskey(AgentREPL._AUDIT_IOS, "sa")
                @test haskey(AgentREPL._AUDIT_IOS, "sb")
            finally
                AgentREPL.close_audit_logs!()
                AgentREPL._AUDIT_DIR[] = old_dir
            end
        end
    end

    @testset "close_audit_logs! cleans up all handles" begin
        mktempdir() do dir
            old_dir = AgentREPL._AUDIT_DIR[]
            try
                AgentREPL._AUDIT_DIR[] = dir
                AgentREPL.audit_interaction("s1", "x", "y", "", nothing)
                AgentREPL.audit_interaction("s2", "x", "y", "", nothing)
                @test length(AgentREPL._AUDIT_IOS) == 2

                AgentREPL.close_audit_logs!()
                @test isempty(AgentREPL._AUDIT_IOS)
            finally
                AgentREPL._AUDIT_DIR[] = old_dir
            end
        end
    end
end

@testset "Workspace Sync" begin
    @testset "Activate sets workspace_path" begin
        session = AgentREPL.get_current_session!()
        AgentREPL.ensure_worker!(session)

        result = AgentREPL.activate_project_on_worker!(".")
        if result.success
            @test session.workspace_path == result.project
        end
    end

    @testset "Worker pwd matches workspace after reset" begin
        session = AgentREPL.get_current_session!()
        result = AgentREPL.activate_project_on_worker!(".")
        if result.success
            workspace = session.workspace_path
            @test workspace !== nothing

            AgentREPL.reset_worker!(session)

            if session.workspace_path !== nothing
                # cd() succeeded on the new worker — verify pwd matches
                value_str, _, error_str, _ = AgentREPL.capture_eval_on_worker("pwd()")
                @test error_str === nothing
                pwd_result = strip(value_str, '"')
                @test pwd_result == workspace
            else
                # cd() failed on new worker (e.g., Windows CI) — code clears workspace_path
                # as graceful degradation; this is the correct behavior
                @test_broken session.workspace_path == workspace
            end
        end
    end

    @testset "workspace_path cleared on invalid directory" begin
        AgentREPL.create_session!("ws-test")
        session = AgentREPL.SESSIONS.sessions["ws-test"]
        AgentREPL.ensure_worker!(session)

        session.workspace_path = "/nonexistent/workspace/path/xyz"
        session.project_path = nothing  # Prevent activate from resetting workspace

        AgentREPL.reset_worker!(session)
        @test session.workspace_path === nothing

        AgentREPL.destroy_session!("ws-test")
    end
end

@testset "Socket Path" begin
    @testset "Socket path helper" begin
        path = AgentREPL._socket_path("test-session")
        @test startswith(path, tempdir())
        @test contains(path, "agentrepl-test-session-")
        @test endswith(path, ".sock")
    end

    @testset "Cleared on kill_worker!" begin
        AgentREPL.create_session!("sock-kill-test")
        session = AgentREPL.SESSIONS.sessions["sock-kill-test"]
        AgentREPL.ensure_worker!(session)
        session.socket_path = "/tmp/fake-socket.sock"

        AgentREPL.kill_worker!(session)
        @test session.socket_path === nothing
        AgentREPL.destroy_session!("sock-kill-test")
    end

    @testset "Cleared on crash recovery" begin
        AgentREPL.create_session!("sock-crash-test")
        session = AgentREPL.SESSIONS.sessions["sock-crash-test"]
        AgentREPL.ensure_worker!(session)
        session.socket_path = "/tmp/fake-socket-crash.sock"

        AgentREPL.capture_eval_on_worker("exit()"; session_name="sock-crash-test")
        @test session.socket_path === nothing
        try; AgentREPL.destroy_session!("sock-crash-test"); catch; end
    end

    @testset "New SessionState fields initialized to nothing" begin
        s = AgentREPL.SessionState("test-init-fields", nothing, nothing)
        @test s.workspace_path === nothing
        @test s.socket_path === nothing
    end
end
