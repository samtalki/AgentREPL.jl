# Test Revise.jl integration

@testset "Revise Integration" begin
    # Clean up any existing sessions first
    _cleanup_all_test_sessions!()

    @testset "is_revise_available with no worker" begin
        session = AgentREPL.create_session!("revise-test")
        # No worker spawned yet
        @test session.worker === nothing
        @test !AgentREPL.is_revise_available(session)
    end

    @testset "is_revise_available with worker" begin
        session = AgentREPL.get_current_session!()
        AgentREPL.ensure_worker!(session)
        # Revise should be loaded (it's in our test project deps)
        @test session.revise_loaded
        @test AgentREPL.is_revise_available(session)
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
        @test session.revise_loaded
        result = AgentREPL.revise_on_worker!(session)
        @test result.success == true
        @test contains(result.message, "Revise completed")
    end

    @testset "includet_on_worker! success and message" begin
        session = AgentREPL.get_current_session!()
        AgentREPL.ensure_worker!(session)
        @test session.revise_loaded

        # Create a temp file with a function definition
        tmpfile = tempname() * ".jl"
        write(tmpfile, "revise_test_func_xyz() = 42\n")
        try
            result = AgentREPL.includet_on_worker!(session, tmpfile)
            @test result.success == true
            @test contains(result.message, "tracking")
            @test contains(result.message, tmpfile)  # Should show actual path, not literal $fp

            # Function should be defined on worker
            val, _, err, _ = AgentREPL.capture_eval_on_worker("revise_test_func_xyz()")
            @test err === nothing
            @test val == "42"
        finally
            rm(tmpfile; force=true)
        end
    end

    @testset "track_file_on_worker! when unavailable" begin
        session = AgentREPL.get_current_session!()
        old_val = session.revise_loaded
        session.revise_loaded = false
        result = AgentREPL.track_file_on_worker!(session, "dummy.jl")
        @test result.success == false
        @test contains(result.message, "not available")
        session.revise_loaded = old_val
    end

    @testset "includet_on_worker! with nonexistent file" begin
        session = AgentREPL.get_current_session!()
        AgentREPL.ensure_worker!(session)
        @test session.revise_loaded

        result = AgentREPL.includet_on_worker!(session, "/nonexistent/file.jl")
        @test result.success == false
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
        @test session.revise_loaded
        status = AgentREPL.get_revise_status(session)
        @test status.available == true
        @test status.tracked_files isa Vector{String}
        @test status.watched_packages isa Vector{String}
    end

    @testset "Hot-reload from an activated project (end-to-end)" begin
        # Exercises loading Revise from the session's own activated project — the path
        # that was broken when Revise loaded before Pkg.activate. Adds Revise to a fresh
        # temp project, then verifies an edit is picked up by revise() without a reset.
        mktempdir() do proj
            src = joinpath(proj, "Hotmod.jl")
            write(src, "hotgreet() = \"v1\"\n")

            session = AgentREPL.get_current_session!()
            AgentREPL.activate_project_on_worker!(proj)
            padd = AgentREPL.run_pkg_action_on_worker("add", ["Revise"])
            @test padd.error === nothing
            AgentREPL.reset_worker!(session)          # respawn: activate proj, then load Revise from it
            @test AgentREPL.is_revise_available(session)

            inc = AgentREPL.includet_on_worker!(session, src)
            @test inc.success
            v1, _, e1, _ = AgentREPL.capture_eval_on_worker("hotgreet()")
            @test e1 === nothing && occursin("v1", v1)

            write(src, "hotgreet() = \"v2\"\n")         # edit the tracked file
            # Revise observes the change through its async file watcher
            # (kqueue/FSEvents on macOS), so a single revise() right after the
            # write can race the watcher. Poll until the new definition lands.
            local rev = (success = false,)
            local v2 = ""
            local e2 = nothing
            revised = false
            for _ in 1:50
                sleep(0.1)
                rev = AgentREPL.revise_on_worker!(session)
                v2, _, e2, _ = AgentREPL.capture_eval_on_worker("hotgreet()")
                if rev.success && e2 === nothing && occursin("v2", v2)
                    revised = true
                    break
                end
            end
            @test rev.success
            @test revised
            @test e2 === nothing && occursin("v2", v2)
        end
    end

    @testset "Cleanup" begin
        for name in collect(keys(AgentREPL.SESSIONS.sessions))
            try; AgentREPL.destroy_session!(name); catch; end
        end
        AgentREPL.SESSIONS.current = nothing
    end
end
