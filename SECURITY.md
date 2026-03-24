# Security Considerations

This document describes the security model of AgentREPL.jl and its implications.

## Transport Security

AgentREPL uses **STDIO transport exclusively**. This is a deliberate design choice for security:

### Why STDIO is More Secure Than HTTP/TCP

| Risk | HTTP/TCP Servers | STDIO (AgentREPL) |
|------|------------------|-------------------|
| Network access | Exposed on port | **Not applicable** |
| Remote attacks | Possible | **Not possible** |
| Port scanning | Discoverable | **Not discoverable** |
| Multi-user access | Other users can connect | **Process-isolated** |
| Firewall bypass | May be needed | **Not needed** |

### How STDIO Works

1. The MCP client (Claude Code) spawns AgentREPL as a subprocess
2. Communication happens via stdin/stdout pipes
3. No network sockets are opened
4. The Julia process inherits the user's permissions
5. When the Claude session ends, the Julia process terminates

This architecture means:
- **No network attack surface** - There's no port to scan or exploit
- **No authentication needed** - Only the parent process can communicate
- **Automatic cleanup** - Process dies when session ends

## Code Execution

AgentREPL evaluates arbitrary Julia code. This is by design - it's the core functionality for AI agent workflows.

### What AgentREPL Protects Against

- **TTFX overhead** - Solved by persistent session
- **Process isolation** - Each Claude session gets its own Julia process
- **Output capture** - Stdout/stderr are captured and returned, not leaked

### What AgentREPL Does NOT Protect Against

| Risk | Status | Mitigation |
|------|--------|------------|
| Malicious code execution | Not protected | Review AI-generated code |
| File system access | Full access | Use sandboxed environment |
| Network access from Julia | Full access | Use network policies |
| Resource exhaustion | No limits | Monitor resource usage |
| Environment variable access | Full access | Sanitize environment |

### The AI Trust Model

AgentREPL trusts the MCP client to send reasonable code. In practice:

1. **Claude Code decides what code to run** - AgentREPL executes it
2. **The user reviews AI suggestions** - Claude shows code before running
3. **Permissions flow from user** - AgentREPL runs with user's permissions

This is similar to running `julia -e "..."` manually - the code runs with your permissions.

## Comparison with Alternatives

### MCPRepl.jl Security

[MCPRepl.jl](https://github.com/hexaeder/MCPRepl.jl) uses HTTP transport on port 3000:

- **Risk**: Any process on the machine can connect
- **Risk**: Network attacks possible if port is exposed
- **Risk**: Could not be registered in Julia General due to security concerns

The [kahliburke fork](https://github.com/kahliburke/MCPRepl.jl) adds security features:
- API key authentication
- IP allowlisting
- Security modes (strict/relaxed/lax)

However, it still opens a network port.

### AgentREPL Security Model

AgentREPL avoids these issues by not opening any network port:

```
MCPRepl.jl:
  [Internet] → [Firewall] → [Port 3000] → [Julia REPL]
                              ↑
                   Attack surface exists

AgentREPL:
  [Claude Code] ⟷ [stdin/stdout] ⟷ [Julia]
                        ↑
              No network attack surface
```

## Best Practices

### For Development Use

AgentREPL is designed for local development workflows:

```bash
# This is the intended use case
claude mcp add julia-repl -- julia --project=/path/to/AgentREPL.jl ...
```

### For Production/Shared Environments

If you need to run AgentREPL in a shared or production environment:

1. **Use containers** - Run Julia in a Docker container with limited permissions
2. **Use seccomp/AppArmor** - Restrict system calls available to Julia
3. **Monitor execution** - Log all code executed via AgentREPL
4. **Set resource limits** - Use ulimit or cgroups to limit CPU/memory
5. **Sanitize environment** - Remove sensitive environment variables

### Things to Avoid

- **Don't expose AgentREPL to the network** - It's designed for local use
- **Don't run with elevated permissions** - Use a regular user account
- **Don't store secrets in environment variables** - Julia can read them
- **Don't rely on AgentREPL for sandboxing** - It executes arbitrary code

## Vulnerability Reporting

If you discover a security vulnerability in AgentREPL, please:

1. **Do not open a public issue**
2. Contact the maintainers privately
3. Provide details about the vulnerability
4. Allow time for a fix before public disclosure

## Disclaimer

This software is provided "AS IS" without warranties. It executes arbitrary code with user permissions. Use at your own risk.

See [LICENSE](LICENSE) for the full Apache 2.0 license terms.
