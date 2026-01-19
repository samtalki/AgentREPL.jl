# highlighting.jl - Julia syntax highlighting with multiple output formats

# Note: JuliaSyntaxHighlighting is imported at module level in AgentREPL.jl
# We use the highlight function from that package

"""
    is_highlighting_enabled() -> Bool

Check if syntax highlighting is enabled via HIGHLIGHT_CONFIG.
Reads from JULIA_REPL_HIGHLIGHT environment variable (default: "true").
"""
function is_highlighting_enabled()::Bool
    return HIGHLIGHT_CONFIG.enabled
end

"""
    get_output_format() -> Symbol

Get the configured output format for syntax highlighting.
Returns `:ansi`, `:markdown`, or `:plain`.
"""
function get_output_format()::Symbol
    return HIGHLIGHT_CONFIG.format
end

"""
    highlight_code(code::String; format::Union{Symbol,Nothing}=nothing) -> String

Apply Julia syntax highlighting to code string.

# Arguments
- `code`: Julia code to highlight
- `format`: Output format override (`:ansi`, `:markdown`, `:plain`).
           If `nothing`, uses `get_output_format()`.

# Returns
Formatted string with highlighting applied (if enabled) or original code.

# Output Formats
- `:ansi` - ANSI escape codes for terminal display (colors)
- `:markdown` - Markdown code fence with julia syntax
- `:plain` - No highlighting, returns code as-is
"""
function highlight_code(code::String; format::Union{Symbol,Nothing}=nothing)::String
    # Return empty code as-is
    if isempty(code)
        return code
    end

    # Check if highlighting is enabled
    if !is_highlighting_enabled()
        return code
    end

    # Determine output format
    output_format = something(format, get_output_format())

    # Plain format - no transformation
    if output_format == :plain
        return code
    end

    # Markdown format - wrap in code fence
    if output_format == :markdown
        return "```julia\n" * strip(code) * "\n```"
    end

    # ANSI format - use JuliaSyntaxHighlighting
    if output_format == :ansi
        io = IOBuffer()
        try
            # highlight() returns an AnnotatedString
            # Use IOContext with :color => true to render ANSI codes
            highlighted = JuliaSyntaxHighlighting.highlight(code)
            ctx = IOContext(io, :color => true)
            print(ctx, highlighted)
            return String(take!(io))
        catch e
            # Graceful degradation - return plain code on error
            @warn "Syntax highlighting failed, using plain text" exception=(e, catch_backtrace()) maxlog=5
            return code
        finally
            close(io)
        end
    end

    # Unknown format - warn and return plain
    @warn "Unknown highlight format: $output_format, using plain" maxlog=1
    return code
end
