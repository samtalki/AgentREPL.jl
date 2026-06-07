# server.jl - MCP server startup

"""
    start_server(; project_dir::Union{String,Nothing}=nothing)

Start the AgentREPL MCP server using STDIO transport.

# Arguments
- `project_dir`: Optional path to a Julia project to activate on the worker.

# Tools Provided
- `eval`: Evaluate Julia code with persistent state
- `reset`: Hard reset (kills worker, spawns fresh one, enables type redefinition)
- `info`: Get session information (version, project, variables, Revise status, worker pid, session name)
- `pkg`: Manage packages (add, rm, status, update, instantiate, resolve, test, develop, free)
- `activate`: Switch active project/environment
- `log_viewer`: Control the log viewer for visual output
- `session`: Manage multiple named sessions (create, switch, list, destroy)
- `revise`: Hot-reload code changes via Revise.jl (revise, track, includet, status)

# Resources Provided
Read-only views of session state (no side effects, never spawn a worker):
`agentrepl://sessions`, `agentrepl://session/variables`, `agentrepl://session/info`,
`agentrepl://session/project`, `agentrepl://session/log`.

# Example
```julia
using AgentREPL
AgentREPL.start_server()  # Blocks, waiting for MCP client
```
"""
function start_server(; project_dir::Union{String,Nothing}=nothing)
    # Set initial project path (worker will be spawned lazily on first use)
    if project_dir !== nothing
        if !isdir(project_dir)
            error("Cannot activate project: directory '$project_dir' not found")
        end
        _INITIAL_PROJECT_PATH[] = project_dir
    end

    # Check for audit log directory
    # JULIA_REPL_AUDIT_DIR: path to directory for persistent audit logs (default: disabled)
    audit_dir = get(ENV, "JULIA_REPL_AUDIT_DIR", nothing)
    if audit_dir !== nothing
        mkpath(audit_dir)
        _AUDIT_DIR[] = audit_dir
        @info "Audit logging enabled" dir=audit_dir
    end

    # Check for log viewer environment variables
    # JULIA_REPL_VIEWER: "auto", "tmux", "file", "none" (default: "none")
    # JULIA_REPL_LOG: path to log file (default: ~/.julia/logs/repl.log)
    viewer_mode_str = get(ENV, "JULIA_REPL_VIEWER", "none")
    viewer_mode = Symbol(viewer_mode_str)
    log_path = get(ENV, "JULIA_REPL_LOG", nothing)

    if viewer_mode != :none
        try
            setup_log_viewer!(; mode=viewer_mode, log_path=log_path)
        catch e
            @warn "Could not set up log viewer, continuing without it" mode=viewer_mode log_path=log_path exception=(e, catch_backtrace())
        end
    end

    # NOTE: Worker is spawned lazily on first tool use to avoid
    # conflicts with MCP STDIO transport during startup

    # Create all tools
    eval_tool = create_eval_tool()
    reset_tool = create_reset_tool()
    info_tool = create_info_tool()
    pkg_tool = create_pkg_tool()
    activate_tool = create_activate_tool()
    log_viewer_tool = create_log_viewer_tool()
    session_tool = create_session_tool()
    revise_tool = create_revise_tool()

    # Resources expose live session state (variables, info, project, log) to the client.
    resources = agentrepl_resources()

    # Declare only the capabilities we actually implement. The framework default
    # advertises resource subscriptions and prompts we don't serve; override it so
    # clients see an accurate picture.
    capabilities = ModelContextProtocol.Capability[
        ModelContextProtocol.ToolCapability(list_changed=false),
        ModelContextProtocol.ResourceCapability(list_changed=false, subscribe=false),
    ]

    # Create and start the server
    server = mcp_server(
        name = "julia-repl",
        version = "0.6.0",
        description = "Persistent Julia REPL for AI agents - multi-session with Revise.jl hot-reloading",
        tools = [eval_tool, reset_tool, info_tool, pkg_tool, activate_tool, log_viewer_tool, session_tool, revise_tool],
        resources = resources,
        capabilities = capabilities
    )

    @info "AgentREPL server starting..." julia_version=VERSION
    start!(server)
end
