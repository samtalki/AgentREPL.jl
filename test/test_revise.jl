# Test Revise.jl integration

@testset "Revise Integration" begin
    # Clean up any existing sessions first
    _cleanup_all_test_sessions!()

    @testset "is_revise_available with no worker" begin
        session = AgentREPL.create_session!("revise-test")
        # No worker spawned yet
        @test session.worker_id === nothing
        @test !AgentREPL.is_revise_available(session)
    end

    @testset "is_revise_available with worker" begin
        session = AgentREPL.get_current_session!()
        AgentREPL.ensure_worker!(session)
        # Revise should be loaded (it's in our test project deps)
        if session.revise_loaded
            @test AgentREPL.is_revise_available(session)
        else
            @test !AgentREPL.is_revise_available(session)
        end
    end

    @testset "is_revise_available returns false when revise_loaded is false" begin
        session = AgentREPL.get_current_session!()
        AgentREPL.ensure_worker!(session)
        old_val = session.revise_loaded
        session.revise_loaded = false
        @test !AgentREPL.is_revise_available(session)
        session.revise_loaded = old_val  # Restore
    end

    @testset "revise_on_worker! when unavailable" begin
        session = AgentREPL.get_current_session!()
        old_val = session.revise_loaded
        session.revise_loaded = false
        result = AgentREPL.revise_on_worker!(session)
        @test result.success == false
        @test contains(result.message, "not available")
        session.revise_loaded = old_val  # Restore
    end

    @testset "revise_on_worker! with live session" begin
        session = AgentREPL.get_current_session!()
        AgentREPL.ensure_worker!(session)
        if session.revise_loaded
            result = AgentREPL.revise_on_worker!(session)
            @test result.success == true
            @test contains(result.message, "Revise completed")
        end
    end

    @testset "get_revise_status when unavailable" begin
        session = AgentREPL.get_current_session!()
        old_val = session.revise_loaded
        session.revise_loaded = false
        status = AgentREPL.get_revise_status(session)
        @test status.available == false
        session.revise_loaded = old_val  # Restore
    end

    @testset "get_revise_status with live session" begin
        session = AgentREPL.get_current_session!()
        AgentREPL.ensure_worker!(session)
        if session.revise_loaded
            status = AgentREPL.get_revise_status(session)
            @test status.available == true
            @test status.tracked_files isa Vector{String}
            @test status.watched_packages isa Vector{String}
        end
    end

    @testset "Cleanup" begin
        for name in collect(keys(AgentREPL.SESSIONS.sessions))
            try; AgentREPL.destroy_session!(name); catch; end
        end
        AgentREPL.SESSIONS.current = nothing
    end
end
