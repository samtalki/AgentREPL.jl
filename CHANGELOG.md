# Changelog

All notable changes to AgentREPL.jl will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.7.1] - 2026-06-07

### Fixed
- Plugin hooks no longer halt the agent after each eval/edit. All three were `type: prompt`,
  which spawns a separate decision-model call per matching tool use and ended the turn with
  "stopped continuation", even for scalar eval results. The two prompt hooks that only
  restated skill guidance (display code before `eval`; expand results for color plots) are
  removed; the `julia-evaluation`/`julia-plot` skills already carry that guidance. The
  post-edit revise hook is rewritten as a non-blocking `type: command` hook
  (`hooks/revise-nudge.sh`) that injects an `additionalContext` reminder to call `revise`
  after a `.jl` edit, so the auto-revise nudge survives without a per-edit model call or a
  turn halt.
- Corrected README references to a removed `julia-language` skill; the auto-triggering
  skills are `julia-evaluation` and `julia-plot`.

## [0.7.0] - 2026-06-07

### Changed
- **Worker backend switched from Distributed.jl to [Malt.jl](https://github.com/JuliaPluto/Malt.jl).** Each session is now a `Malt.Worker`. Malt keeps worker stdout/stderr on private pipes, so worker output can no longer reach the stdout MCP JSON-RPC transport; the pipes are drained to the server's stderr. Removes Distributed's global cluster state and replaces hand-rolled lifecycle/crash handling with Malt's `stop`/`isrunning`/`TerminatedWorkerException`. `info` and `session` now report the worker OS pid instead of a cluster id.

### Added
- **MCP resources** exposing live session state for clients to read/@-mention without an extra tool call: `agentrepl://sessions`, `agentrepl://session/variables`, `agentrepl://session/info`, `agentrepl://session/project`, `agentrepl://session/log`.
- **MCP prompts** exposing reusable Julia workflows as slash commands that work without the plugin: `julia-dev-setup`, `julia-benchmark`, `julia-debug-error`. The server declares `PromptCapability`.
- **Visible out-of-band worker output**: drained worker lines (spawn-time precompile, async prints, long `pkg`/precompile progress) are kept in a per-session `recent_output` ring and surfaced via the `agentrepl://session/log` resource and the live log viewer.
- **Tool titles** on all eight tools (human-friendly display names in the client).
- **Surfaced worker-setup failures**: Revise-load and project-activation failures are recorded in the session and shown in `info` and the next eval result, instead of only being logged to stderr.
- **Transport-cleanliness regression test** (E2E) asserting worker output never reaches the JSON-RPC stream, plus an E2E job in CI (`AGENTREPL_E2E=true` on Julia 1.12).

### Fixed
- **Clean error stacktraces**: eval errors no longer show AgentREPL's harness frames or the `LoadError` wrapper. The message is the real exception and the stacktrace stops at user code.
- **Revise hot-reload for activated projects**: Revise is loaded after `Pkg.activate`, so hot-reloading tracks the session's activated environment instead of AgentREPL's own.
- Server declares only the capabilities it implements (Tools + Resources + Prompts), instead of the framework default that advertised resource subscriptions it does not serve.
- `info` no longer lists internal temporaries as user variables (the introspection expression is scoped and a baseline of `Main` symbols is excluded).

## [0.6.0] - 2026-03-23

### Added
- **Multi-session support**: Create, switch, list, and destroy named sessions with isolated workers
- **Revise.jl integration**: Auto-loaded on workers for hot-reloading code changes without restart
- **`session` MCP tool**: Manage multiple concurrent Julia REPL sessions
- **`revise` MCP tool**: Hot-reload file changes (revise, track, includet, status)
- **Optional `session` parameter**: All tools except `log_viewer` and `session` now accept a session name to target specific sessions
- **PostToolUse hook**: Automatically calls `revise` after editing `.jl` files
- **New skills**: julia-session, julia-revise, julia-develop, julia-language (deep Julia expertise)
- Session isolation: each session has its own worker, variables, packages, and project environment
- `test/test_sessions.jl` for multi-session tests

### Changed
- Migrated all commands from `commands/` to `skills/` format
- `info` tool now reports Revise.jl availability and session name
- `reset` tool now reports Revise.jl reload status
- `SKILL.md` expanded with Revise workflow, session management, performance analysis, debugging guidance
- Plugin version bumped to 0.6.0

### Removed
- **Tmux REPL mode**: Deprecated tmux bidirectional REPL code removed entirely
- `TmuxREPLState`, `REPL_MODE`, `TMUX_ENABLED` types/globals removed
- `create_mode_tool()` removed
- `commands/` directory removed (migrated to skills/)

## [0.5.0] - 2026-01-19

First public release of AgentREPL.jl.

### Features
- Persistent Julia REPL via MCP STDIO transport
- Worker subprocess model (Distributed.jl) for true hard reset
- Type redefinition support after reset
- Julia syntax highlighting (JuliaSyntaxHighlighting.jl stdlib)
- 7 MCP tools: eval, reset, info, pkg, activate, log_viewer, mode
- Claude Code plugin with auto-configuration
- Slash commands: /julia-reset, /julia-info, /julia-pkg, /julia-activate
- Environment variable configuration (JULIA_REPL_HIGHLIGHT, JULIA_REPL_OUTPUT_FORMAT)
- Log viewer for visual output monitoring
- Modular source code structure

### Package Management
- Full Pkg.jl integration: add, rm, status, update, instantiate, resolve, test, develop, free
- Project activation with shared environment support (@v1.10, @myenv)

### Requirements
- Julia 1.12+ (for JuliaSyntaxHighlighting stdlib)
- ModelContextProtocol.jl 0.4+

### Note
Tmux bidirectional REPL mode is deprecated. Use distributed mode with log_viewer instead. (Removed in 0.6.0)

[Unreleased]: https://github.com/samtalki/AgentREPL.jl/compare/v0.7.1...HEAD
[0.7.1]: https://github.com/samtalki/AgentREPL.jl/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/samtalki/AgentREPL.jl/compare/v0.6.2...v0.7.0
[0.6.0]: https://github.com/samtalki/AgentREPL.jl/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/samtalki/AgentREPL.jl/releases/tag/v0.5.0
