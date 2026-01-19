"""
    AgentREPL

A persistent Julia REPL for AI agents via MCP (Model Context Protocol).

AgentREPL solves Julia's "Time to First X" (TTFX) problem by maintaining a persistent
worker subprocess. Instead of spawning fresh Julia processes for each command (1-2s startup),
the REPL stays alive and you only pay the startup cost once.

# Architecture

AgentREPL uses a worker subprocess model via Distributed.jl:
- The MCP server runs in the main process (STDIO transport)
- Code evaluation happens in a spawned worker process
- `reset` kills the worker and spawns a fresh one (enables type redefinition)
- `activate` switches the worker's project/environment

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
- `info` - Get session info (Julia version, project, variables, worker ID)
- `pkg` - Manage packages (add, rm, status, update, instantiate, resolve, test, develop, free)
- `activate` - Switch active project/environment
- `log_viewer` - Control log viewer for visual output
- `mode` - Switch between distributed and tmux modes (tmux is deprecated)

# See Also

- [ModelContextProtocol.jl](https://github.com/JuliaSMLM/ModelContextProtocol.jl) - MCP framework
- [Modern Julia Workflows](https://modernjuliaworkflows.org/) - Best practices guide
"""
module AgentREPL

using ModelContextProtocol
using Distributed
using Pkg
using Dates
using JuliaSyntaxHighlighting

export start_server

# Include files in dependency order
include("types.jl")
include("highlighting.jl")
include("formatting.jl")
include("worker.jl")
include("packages.jl")
include("logging.jl")
include("deprecated/tmux.jl")
include("tools.jl")
include("server.jl")

end # module
