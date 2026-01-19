# server.jl - MCP server startup

"""
    start_server(; project_dir::Union{String,Nothing}=nothing)

Start the AgentREPL MCP server using STDIO transport.

# Arguments
- `project_dir`: Optional path to a Julia project to activate on the worker.

# Tools Provided
- `eval`: Evaluate Julia code with persistent state
- `reset`: Hard reset (kills worker, spawns fresh one, enables type redefinition)
- `info`: Get session information (version, project, variables, worker ID)
- `pkg`: Manage packages (add, rm, status, update, instantiate, resolve, test, develop, free)
- `activate`: Switch active project/environment
- `log_viewer`: Control the log viewer for visual output
- `mode`: Switch between distributed and tmux modes (tmux is deprecated)

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
        WORKER.project_path = project_dir
    end

    # Check for REPL mode environment variable
    # JULIA_REPL_MODE: "distributed" (default) or "tmux" (deprecated)
    repl_mode_str = get(ENV, "JULIA_REPL_MODE", "distributed")
    REPL_MODE[] = Symbol(repl_mode_str)

    if REPL_MODE[] == :tmux
        if !TMUX_ENABLED[]
            @warn "JULIA_REPL_MODE=tmux requested but tmux mode is deprecated. Set JULIA_REPL_ENABLE_TMUX=true to enable."
            REPL_MODE[] = :distributed
        else
            # Set project path for tmux REPL
            TMUX_REPL.project_path = project_dir
            warn_tmux_deprecated()
            @info "Using tmux-based bidirectional REPL mode (DEPRECATED)"
        end
    end

    if REPL_MODE[] == :distributed
        # Check for log viewer environment variables (only for distributed mode)
        # JULIA_REPL_VIEWER: "auto", "tmux", "file", "none" (default: "none")
        # JULIA_REPL_LOG: path to log file (default: ~/.julia/logs/repl.log)
        viewer_mode_str = get(ENV, "JULIA_REPL_VIEWER", "none")
        viewer_mode = Symbol(viewer_mode_str)
        log_path = get(ENV, "JULIA_REPL_LOG", nothing)

        if viewer_mode != :none
            setup_log_viewer!(; mode=viewer_mode, log_path=log_path)
        end
    end

    # NOTE: Worker/tmux session is spawned lazily on first tool use to avoid
    # conflicts with MCP STDIO transport during startup

    # Create all tools
    eval_tool = create_eval_tool()
    reset_tool = create_reset_tool()
    info_tool = create_info_tool()
    pkg_tool = create_pkg_tool()
    activate_tool = create_activate_tool()
    log_viewer_tool = create_log_viewer_tool()
    mode_tool = create_mode_tool()

    # Create and start the server
    server = mcp_server(
        name = "julia-repl",
        version = "0.3.0",
        description = "Persistent Julia REPL for AI agents - eliminates TTFX",
        tools = [eval_tool, reset_tool, info_tool, pkg_tool, activate_tool, log_viewer_tool, mode_tool]
    )

    @info "AgentREPL server starting..." julia_version=VERSION
    start!(server)
end
