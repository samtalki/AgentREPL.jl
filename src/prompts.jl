# prompts.jl - MCP prompts: reusable Julia workflows exposed to the client.
#
# Claude Code surfaces these as slash commands. Unlike the plugin skills, they ship
# with the MCP server itself, so they work even without the plugin. Each is a static
# user-message template; the framework's get_prompt handler fills `{arg}` placeholders
# and resolves `{?arg?…}` conditional blocks.

"""
    agentrepl_prompts() -> Vector{MCPPrompt}

Build the MCP prompt templates registered in `start_server`.
"""
function agentrepl_prompts()
    MCPPrompt[
        MCPPrompt(
            name = "julia-dev-setup",
            description = "Set up a Julia package for interactive development with hot-reload.",
            arguments = [PromptArgument(name = "path", description = "Path to the package or project directory", required = true)],
            messages = [PromptMessage(content = TextContent(text =
                "Set up the Julia project at `{path}` for interactive development:\n" *
                "1. activate(path=\"{path}\")\n" *
                "2. pkg(action=\"instantiate\") to install its dependencies\n" *
                "3. pkg(action=\"add\", packages=\"Revise\") if Revise is not already a dependency\n" *
                "4. reset() so the fresh worker loads Revise from the project\n" *
                "5. revise(action=\"status\") to confirm hot-reload is active\n" *
                "Then edit .jl files and call revise(action=\"revise\") to load changes without losing session state."))]
        ),
        MCPPrompt(
            name = "julia-benchmark",
            description = "Benchmark a Julia expression, accounting for compilation.",
            arguments = [PromptArgument(name = "code", description = "The Julia expression to benchmark", required = true)],
            messages = [PromptMessage(content = TextContent(text =
                "Benchmark this Julia code, separating compilation from run time:\n" *
                "```julia\n{code}\n```\n" *
                "1. Run it once with eval to trigger compilation (ignore that first timing).\n" *
                "2. Run it again and report the elapsed time eval shows.\n" *
                "3. For a rigorous number, eval `using BenchmarkTools` (add it with pkg if needed) and report `@benchmark` of the expression.\n" *
                "Use isolated=true so the benchmark leaves no variables in the session."))]
        ),
        MCPPrompt(
            name = "julia-debug-error",
            description = "Diagnose a Julia error from the REPL.",
            arguments = [
                PromptArgument(name = "code", description = "The code that errors", required = true),
                PromptArgument(name = "error", description = "The error message, if you have it", required = false),
            ],
            messages = [PromptMessage(content = TextContent(text =
                "Diagnose this failing Julia code:\n" *
                "```julia\n{code}\n```\n" *
                "{?error?The reported error was: {error}\n}" *
                "Reproduce it with eval (use isolated=true to avoid polluting the session), read the stacktrace, " *
                "and check the types of the inputs with eval (e.g. `typeof(x)`). Then explain the cause and propose a fix."))]
        ),
    ]
end
