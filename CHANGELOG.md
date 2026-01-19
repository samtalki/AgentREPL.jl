# Changelog

All notable changes to AgentREPL.jl will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Julia syntax highlighting** for code in REPL output
  - New `src/highlighting.jl` module using JuliaSyntaxHighlighting.jl (official Julia package)
  - Highlights keywords, strings, comments, numbers in both headless and logger output
  - Environment variable configuration:
    - `JULIA_REPL_HIGHLIGHT`: Enable/disable highlighting (default: "true")
    - `JULIA_REPL_OUTPUT_FORMAT`: Output format - "ansi", "markdown", or "plain" (default: "ansi")
  - ANSI format for terminal color output (logger and headless)
  - Markdown format wraps code in ` ```julia ` fences (for future Claude Code markdown rendering)
  - Graceful degradation to plain text if highlighting fails

### Changed
- `format_result()` now applies syntax highlighting to code input
- `log_interaction()` now applies ANSI syntax highlighting for terminal viewer

## [0.4.0] - 2025-01-19

### Added
- Split monolithic `src/AgentREPL.jl` into logical modules for better maintainability:
  - `types.jl` - State structs and global constants
  - `formatting.jl` - Result formatting and stacktrace truncation
  - `worker.jl` - Distributed worker lifecycle management
  - `packages.jl` - Package management and project activation
  - `logging.jl` - Log viewer functionality
  - `tools.jl` - MCP tool definitions
  - `server.jl` - Server startup function
  - `deprecated/tmux.jl` - Deprecated tmux REPL code
- `JULIA_REPL_ENABLE_TMUX` environment variable to opt-in to deprecated tmux mode

### Deprecated
- **Tmux bidirectional REPL mode** is now deprecated and disabled by default
  - The tmux mode has unfixable marker pollution issues (completion detection marker visible in terminal)
  - Use distributed mode with `log_viewer` tool or `JULIA_REPL_VIEWER=auto` for visual output
  - Set `JULIA_REPL_ENABLE_TMUX=true` to force-enable (not recommended)

### Changed
- Main `src/AgentREPL.jl` reduced from 1556 lines to 64 lines (module shell with includes)
- Updated all documentation to reflect new file structure and tmux deprecation

## [0.3.0] - 2025-01-19

### Added
- `Pkg.test()` support - run package tests via `pkg(action="test")`
- `Pkg.develop()` support - put packages in development mode via `pkg(action="develop")`
- `Pkg.free()` support - exit development mode via `pkg(action="free")`
- Shared environment activation support (`@v1.10`, `@myenv` syntax)
- Improved display for non-stringifiable types (e.g., `JSON3.Object`)
- Comprehensive docstrings for all structs and constants

### Changed
- Renamed from AgentEval.jl to AgentREPL.jl
- Updated documentation to reflect modern Julia workflows

### Fixed
- Shared environment activation now works correctly (expands `@name` to `~/.julia/environments/name`)
- Display of types that can't be converted to strings via `repr()` or `string()`

## [0.2.0] - 2025-01-15

### Added
- Claude Code plugin with auto-configured MCP server
- Slash commands: `/julia-reset`, `/julia-info`, `/julia-pkg`, `/julia-activate`
- Best practices skill for Julia development
- Worker subprocess model via Distributed.jl for true hard reset capability
- Type redefinition support (impossible with in-process reset)
- Expression-based IPC to avoid closure serialization issues
- Log viewer feature for real-time output monitoring

### Changed
- Architecture changed from in-process to worker subprocess model
- Worker spawning deferred to first use to avoid STDIO conflicts with MCP
- Project environment now persists across `reset` calls

### Fixed
- MCP STDIO transport conflict with worker spawning at startup
- Closure serialization issues with `remotecall_fetch`
- Missing Distributed dependency

## [0.1.0] - 2025-01-10

### Added
- Initial release as AgentEval.jl
- Persistent Julia REPL via MCP STDIO transport
- `eval` tool for code evaluation with output capture
- `reset` tool for session reset
- `info` tool for session information
- `pkg` tool with `add`, `rm`, `status`, `update`, `instantiate`, `resolve` actions
- `activate` tool for project/environment switching
- CLAUDE.md guidance for Claude Code
- Comparison documentation with alternative packages
- SECURITY.md with security considerations

[Unreleased]: https://github.com/samtalki/AgentREPL.jl/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/samtalki/AgentREPL.jl/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/samtalki/AgentREPL.jl/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/samtalki/AgentREPL.jl/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/samtalki/AgentREPL.jl/releases/tag/v0.1.0
