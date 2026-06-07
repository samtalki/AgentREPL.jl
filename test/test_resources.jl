using Test
using AgentREPL
const A = AgentREPL

# Drop all sessions so we start from a clean, worker-free registry.
function _reset_sessions!()
    for name in collect(keys(A.SESSIONS.sessions))
        try; A.destroy_session!(name); catch; end
    end
    A.SESSIONS.current = nothing
end

@testset "MCP Resources" begin
    _reset_sessions!()

    @testset "_resource_safe ok/error discriminant" begin
        ok = A._resource_safe(() -> (a = 1, b = "x"))
        @test ok.ok == true
        @test ok.a == 1 && ok.b == "x"

        bad = A._resource_safe(() -> error("boom"))
        @test bad.ok == false
        @test occursin("boom", bad.error)

        # Cancellation / OOM must propagate, never be flattened into `error`.
        @test_throws InterruptException A._resource_safe(() -> throw(InterruptException()))
    end

    @testset "reads never spawn a worker" begin
        _reset_sessions!()
        s = A.get_current_session!()          # "default", no worker yet
        @test A.worker_live(s) == false

        info = A._resource_info()
        @test info.ok && info.worker_spawned == false && info.worker_pid === nothing
        @test info.julia_version == string(VERSION)

        vars = A._resource_variables()
        @test vars.ok && vars.worker_spawned == false && isempty(vars.variables)

        proj = A._resource_project()
        @test proj.ok && haskey(proj, :project_dir) && haskey(proj, :manifest_present)

        @test A.worker_live(s) == false        # none of the reads spawned a worker
    end

    @testset "reads reflect a live worker" begin
        _reset_sessions!()
        s = A.get_current_session!()
        A.capture_eval_on_worker("res_var = 123")
        @test A.worker_live(s)

        info = A._resource_info()
        @test info.worker_spawned == true && info.worker_pid isa Int
        @test info.loaded_modules > 0

        vars = A._resource_variables()
        @test any(v -> v.name == "res_var", vars.variables)

        sess = A._resource_sessions()
        @test sess.ok
        @test any(row -> row.name == s.name && row.worker_pid isa Int, sess.sessions)
        # field names unified with info: rows carry `revise_loaded`, not `revise`
        @test all(haskey(row, :revise_loaded) for row in sess.sessions)
    end

    @testset "project resource shape" begin
        proj = A._resource_project()
        @test proj.ok
        @test haskey(proj, :project_dir)
        @test haskey(proj, :project_toml)
        @test haskey(proj, :manifest_present)
    end

    @testset "log resource: audit disabled vs enabled + tail cap" begin
        A.close_audit_logs!()                 # clear any handles left by other suites
        @test A._AUDIT_DIR[] === nothing
        disabled = A._resource_log()
        @test disabled.ok && disabled.audit_enabled == false

        mktempdir() do dir
            old = A._AUDIT_DIR[]
            try
                A.close_audit_logs!()
                A._AUDIT_DIR[] = dir
                s = A.get_current_session!()

                empty_log = A._resource_log()
                @test empty_log.audit_enabled == true && isempty(empty_log.tail)

                for i in 1:5
                    A.audit_interaction(s.name, "x=$i", "$i", "", nothing; elapsed=0.001)
                end
                got = A._resource_log()
                @test got.audit_enabled == true && !isempty(got.tail)

                # Each interaction writes several lines; 250 of them blows past the
                # 200-line tail cap, so the resource returns exactly the last 200.
                for i in 1:250
                    A.audit_interaction(s.name, "y=$i", "$i", "", nothing)
                end
                big = A._resource_log()
                @test length(big.tail) == 200
            finally
                A.close_audit_logs!()
                A._AUDIT_DIR[] = old
            end
        end
    end

    @testset "agentrepl_resources registers the five resources" begin
        rs = A.agentrepl_resources()
        uris = Set(string(r.uri) for r in rs)
        @test length(rs) == 5
        for u in ("agentrepl://sessions", "agentrepl://session/variables",
                  "agentrepl://session/info", "agentrepl://session/project",
                  "agentrepl://session/log")
            @test u in uris
        end
    end

    _reset_sessions!()
end
