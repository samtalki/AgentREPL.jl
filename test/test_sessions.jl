# Test multi-session management

@testset "Session Management" begin
    # Clean up any existing sessions first
    for name in collect(keys(AgentREPL.SESSIONS.sessions))
        try; AgentREPL.destroy_session!(name); catch; end
    end
    AgentREPL.SESSIONS.current = nothing

    @testset "Default session auto-creation" begin
        session = AgentREPL.get_current_session!()
        @test session.name == "default"
        @test session.worker_id === nothing  # Lazy spawning
        @test AgentREPL.SESSIONS.current == "default"
    end

    @testset "Create named session" begin
        session = AgentREPL.create_session!("test-session")
        @test session.name == "test-session"
        @test AgentREPL.SESSIONS.current == "test-session"
        @test haskey(AgentREPL.SESSIONS.sessions, "test-session")
    end

    @testset "Switch session" begin
        AgentREPL.create_session!("session-a")
        AgentREPL.create_session!("session-b")

        AgentREPL.switch_session!("session-a")
        @test AgentREPL.SESSIONS.current == "session-a"

        AgentREPL.switch_session!("session-b")
        @test AgentREPL.SESSIONS.current == "session-b"
    end

    @testset "Switch to nonexistent session throws" begin
        @test_throws ErrorException AgentREPL.switch_session!("nonexistent")
    end

    @testset "List sessions" begin
        sessions = AgentREPL.list_sessions()
        @test length(sessions) >= 2
        names = [s.name for s in sessions]
        @test "session-a" in names
        @test "session-b" in names
    end

    @testset "Session isolation" begin
        AgentREPL.switch_session!("session-a")
        AgentREPL.capture_eval_on_worker("session_a_var = 111")

        AgentREPL.switch_session!("session-b")
        AgentREPL.capture_eval_on_worker("session_b_var = 222")

        # session-b should not have session-a's variable
        _, _, error_str, _ = AgentREPL.capture_eval_on_worker("session_a_var")
        @test error_str !== nothing
        @test contains(error_str, "UndefVarError")

        # session-a should not have session-b's variable
        AgentREPL.switch_session!("session-a")
        _, _, error_str2, _ = AgentREPL.capture_eval_on_worker("session_b_var")
        @test error_str2 !== nothing
        @test contains(error_str2, "UndefVarError")

        # But each session's own variable should exist
        value_a, _, _, _ = AgentREPL.capture_eval_on_worker("session_a_var")
        @test value_a == "111"

        AgentREPL.switch_session!("session-b")
        value_b, _, _, _ = AgentREPL.capture_eval_on_worker("session_b_var")
        @test value_b == "222"
    end

    @testset "WORKER global stays in sync" begin
        AgentREPL.switch_session!("session-a")
        session_a = AgentREPL.SESSIONS.sessions["session-a"]
        @test AgentREPL.WORKER.worker_id == session_a.worker_id

        AgentREPL.switch_session!("session-b")
        session_b = AgentREPL.SESSIONS.sessions["session-b"]
        @test AgentREPL.WORKER.worker_id == session_b.worker_id
    end

    @testset "Destroy session" begin
        # Create a session and eval something to spawn worker
        AgentREPL.create_session!("doomed")
        AgentREPL.capture_eval_on_worker("x = 1")
        doomed_worker = AgentREPL.SESSIONS.sessions["doomed"].worker_id
        @test doomed_worker !== nothing

        # Switch away and destroy
        AgentREPL.switch_session!("session-a")
        AgentREPL.destroy_session!("doomed")

        @test !haskey(AgentREPL.SESSIONS.sessions, "doomed")
    end

    @testset "Session-targeted eval" begin
        AgentREPL.switch_session!("session-a")
        AgentREPL.capture_eval_on_worker("targeted_var = 999"; session_name="session-b")

        # The variable should be in session-b, not session-a
        _, _, err_a, _ = AgentREPL.capture_eval_on_worker("targeted_var")
        @test err_a !== nothing  # Not in session-a

        _, _, err_b, _ = AgentREPL.capture_eval_on_worker("targeted_var"; session_name="session-b")
        @test err_b === nothing  # Is in session-b
    end

    @testset "Session inherits initial project path" begin
        AgentREPL._INITIAL_PROJECT_PATH[] = "/test/initial/project"
        try
            session = AgentREPL.create_session!("inherit-test")
            @test session.project_path == "/test/initial/project"
            AgentREPL.destroy_session!("inherit-test")
        finally
            AgentREPL._INITIAL_PROJECT_PATH[] = nothing
        end
    end

    @testset "Explicit project_path overrides initial" begin
        AgentREPL._INITIAL_PROJECT_PATH[] = "/test/initial/project"
        try
            session = AgentREPL.create_session!("override-test"; project_path="/explicit/path")
            @test session.project_path == "/explicit/path"
            AgentREPL.destroy_session!("override-test")
        finally
            AgentREPL._INITIAL_PROJECT_PATH[] = nothing
        end
    end

    @testset "Cleanup sessions" begin
        for name in collect(keys(AgentREPL.SESSIONS.sessions))
            try; AgentREPL.destroy_session!(name); catch; end
        end
        AgentREPL.SESSIONS.current = nothing
        AgentREPL.WORKER.worker_id = nothing
        AgentREPL.WORKER.project_path = nothing
    end
end
