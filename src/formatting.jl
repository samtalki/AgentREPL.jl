# formatting.jl - Result formatting and stacktrace truncation

const SPARKLINE_BLOCKS = ['▁','▂','▃','▄','▅','▆','▇','█']

"""
    sparkline(values::AbstractVector{<:Real}) -> String

Render a sparkline using Unicode block characters (▁▂▃▄▅▆▇█).
"""
function sparkline(values::AbstractVector{<:Real})
    isempty(values) && return ""
    lo, hi = extrema(values)
    span = hi - lo
    span == 0 && return repeat("▄", length(values))
    return String([SPARKLINE_BLOCKS[clamp(round(Int, (v - lo) / span * 7) + 1, 1, 8)] for v in values])
end

"""
    truncate_output(text::String, max_chars::Int; use_ansi::Bool=false) -> String

Truncate text to `max_chars` characters, keeping head (60%) and tail (40%)
with a marker showing how many characters were truncated.

When `use_ansi` is true, the truncation marker uses dim ANSI styling with ⋯ ellipsis.
"""
function truncate_output(text::String, max_chars::Int; use_ansi::Bool=false)
    length(text) <= max_chars && return text

    head_chars = div(max_chars * 60, 100)
    tail_chars = max_chars - head_chars
    removed = length(text) - head_chars - tail_chars

    marker = if use_ansi
        "\n\n$(ANSI_DIM)⋯ [$(removed) characters truncated] ⋯$(ANSI_RESET)\n\n"
    else
        "\n\n... [$(removed) characters truncated] ...\n\n"
    end

    return first(text, head_chars) * marker * last(text, tail_chars)
end

"""
    format_elapsed(elapsed::Float64) -> String

Format elapsed time as human-readable string.
"""
function format_elapsed(elapsed::Float64)
    if elapsed < 1.0
        return "[$(round(elapsed * 1000; digits=1))ms]"
    else
        return "[$(round(elapsed; digits=2))s]"
    end
end

"""
    truncate_stacktrace(error_str::String; max_frames::Int=5) -> String

Truncate a stacktrace to the most relevant frames.
Keeps the error message and first few frames, adds note if truncated.
"""
function truncate_stacktrace(error_str::String; max_frames::Int=5)
    lines = split(error_str, '\n')

    # Find where stacktrace starts (after "Stacktrace:")
    stacktrace_idx = findfirst(l -> startswith(strip(l), "Stacktrace:"), lines)

    if stacktrace_idx === nothing
        return error_str  # No stacktrace, return as-is
    end

    # Keep error message and "Stacktrace:" line
    result_lines = lines[1:stacktrace_idx]

    # Count frames (lines starting with [N])
    remaining_lines = lines[stacktrace_idx+1:end]
    frame_count = 0
    last_included_idx = 0

    for (i, line) in enumerate(remaining_lines)
        if occursin(r"^\s*\[\d+\]", line)
            frame_count += 1
            if frame_count <= max_frames
                last_included_idx = i
            end
        elseif frame_count <= max_frames
            last_included_idx = i
        end
    end

    if frame_count > max_frames
        append!(result_lines, remaining_lines[1:last_included_idx])
        push!(result_lines, "  ... ($(frame_count - max_frames) more frames truncated)")
    else
        append!(result_lines, remaining_lines)
    end

    return join(result_lines, '\n')
end

"""
    style_error(error_str::String) -> String

Apply ANSI styling to an error string: bold red for the error message,
dim for the stacktrace.
"""
function style_error(error_str::String)
    lines = split(error_str, '\n')
    stacktrace_idx = findfirst(l -> startswith(strip(l), "Stacktrace:"), lines)

    if stacktrace_idx === nothing
        return ANSI_RED * ANSI_BOLD * error_str * ANSI_RESET
    end

    # Bold red for error message lines (before Stacktrace:)
    error_lines = join(lines[1:stacktrace_idx-1], '\n')
    # Dim for stacktrace (including "Stacktrace:" header)
    trace_lines = join(lines[stacktrace_idx:end], '\n')
    return ANSI_RED * ANSI_BOLD * error_lines * ANSI_RESET * "\n" * ANSI_DIM * trace_lines * ANSI_RESET
end

"""
    format_result(code, value_str, output, error_str; elapsed=nothing, max_output=50_000, max_stackframes=5)

Format the evaluation result for display in REPL style.
Shows the code with `julia>` prompt followed by output and result.
Applies syntax highlighting based on JULIA_REPL_HIGHLIGHT and JULIA_REPL_OUTPUT_FORMAT settings.

When ANSI output is enabled, applies Julia REPL-style styling:
- Bold green `julia>` prompt
- Dim timing
- Bold red errors with dim stacktraces
- Dim `→` prefix when both stdout and return value exist

Keyword arguments:
- `elapsed`: Execution time in seconds (appended to output as `[Xs]` or `[Xms]`)
- `max_output`: Maximum characters for output/value before truncation (default: 50,000)
- `max_stackframes`: Maximum stacktrace frames to show (default: 5)
"""
function format_result(code::String, value_str::String, output::String, error_str::Union{String,Nothing};
                        elapsed::Union{Float64,Nothing}=nothing,
                        max_output::Int=50_000,
                        max_stackframes::Int=5)
    parts = String[]
    use_ansi = is_highlighting_enabled() && get_output_format() == :ansi

    # Apply syntax highlighting to code (uses configured output format)
    highlighted_code = highlight_code(code)

    # Show code with julia> prompt (like REPL)
    code_lines = split(strip(highlighted_code), '\n')
    if use_ansi
        push!(parts, ANSI_GREEN * ANSI_BOLD * "julia> " * ANSI_RESET * code_lines[1])
    else
        push!(parts, "julia> " * code_lines[1])
    end
    for line in code_lines[2:end]
        push!(parts, "       " * line)
    end
    push!(parts, "")

    # Apply output truncation
    output = truncate_output(output, max_output; use_ansi)
    value_str = truncate_output(value_str, max_output; use_ansi)

    # Show printed output first (if any)
    has_output = !isempty(strip(output))
    if has_output
        push!(parts, strip(output))
    end

    # Show result or error
    if error_str !== nothing
        truncated_error = truncate_stacktrace(error_str; max_frames=max_stackframes)
        if use_ansi
            push!(parts, style_error(truncated_error))
        else
            push!(parts, truncated_error)
        end
    else
        # Add → prefix when both output and non-nothing return value exist
        has_value = !isempty(strip(value_str)) && strip(value_str) != "nothing"
        if use_ansi && has_output && has_value
            push!(parts, ANSI_DIM * "→" * ANSI_RESET * " " * value_str)
        else
            push!(parts, value_str)
        end
    end

    # Append timing
    if elapsed !== nothing
        push!(parts, "")
        if use_ansi
            push!(parts, ANSI_DIM * format_elapsed(elapsed) * ANSI_RESET)
        else
            push!(parts, format_elapsed(elapsed))
        end
    end

    return join(parts, "\n")
end
