"""
    AgentREPL

A persistent Julia REPL for AI agents via MCP (Model Context Protocol).

AgentREPL solves Julia's "Time to First X" (TTFX) problem by maintaining persistent
worker subprocesses. Instead of spawning fresh Julia processes for each command (1-2s startup),
the REPL stays alive and you only pay the startup cost once.

# Architecture

AgentREPL uses a multi-session worker subprocess model via Malt.jl:
- The MCP server runs in the main process (STDIO transport)
- Code evaluation happens in spawned worker processes (one per session)
- Multiple named sessions can run concurrently with isolated state
- `reset` kills a session's worker and spawns a fresh one (enables type redefinition)
- `activate` switches a session's project/environment
- Revise.jl is auto-loaded on workers for hot-reloading support

# Quick Start

Using the Claude Code plugin (recommended):
```bash
claude /plugin add samtalki/AgentREPL.jl
```

Or manual MCP configuration:
```bash
claude mcp add julia-repl -- julia --project=/path/to/AgentREPL.jl /path/to/AgentREPL.jl/bin/julia-repl-server
```

# Tools Provided

- `eval` - Evaluate Julia code with persistent state
- `reset` - Hard reset (kills worker, spawns fresh one, enables type redefinition)
- `info` - Get session info (Julia version, project, variables, Revise status, worker ID, session name)
- `pkg` - Manage packages (add, rm, status, update, instantiate, resolve, test, develop, free)
- `activate` - Switch active project/environment
- `log_viewer` - Control log viewer for visual output
- `session` - Manage multiple named sessions (create, switch, list, destroy)
- `revise` - Hot-reload code changes via Revise.jl (revise, track, includet, status)

# See Also

- [ModelContextProtocol.jl](https://github.com/JuliaSMLM/ModelContextProtocol.jl) - MCP framework
- [Modern Julia Workflows](https://modernjuliaworkflows.org/) - Best practices guide
- [Revise.jl](https://github.com/timholy/Revise.jl) - Hot-reloading for Julia
"""
module AgentREPL

using ModelContextProtocol
import Malt
using Pkg
using Dates
using JuliaSyntaxHighlighting

export start_server

# Include files in dependency order
include("types.jl")
include("highlighting.jl")
include("formatting.jl")
include("sessions.jl")
include("worker.jl")
include("revise.jl")
include("packages.jl")
include("logging.jl")
include("attach.jl")
include("tools.jl")
include("resources.jl")
include("prompts.jl")
include("server.jl")

function __init__()
    _init_highlight_config!()
    atexit(_cleanup_all_workers!)
end

end # module
