# formatting.jl - Result formatting and stacktrace truncation

"""
    truncate_output(text::String, max_chars::Int) -> String

Truncate text to `max_chars` characters, keeping head (60%) and tail (40%)
with a marker showing how many characters were truncated.
"""
function truncate_output(text::String, max_chars::Int)
    length(text) <= max_chars && return text

    head_chars = div(max_chars * 60, 100)
    tail_chars = max_chars - head_chars
    removed = length(text) - head_chars - tail_chars

    return text[1:head_chars] *
        "\n\n... [$(removed) characters truncated] ...\n\n" *
        text[end-tail_chars+1:end]
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
    format_result(code, value_str, output, error_str; elapsed=nothing, max_output=50_000, max_stackframes=5)

Format the evaluation result for display in REPL style.
Shows the code with `julia>` prompt followed by output and result.
Applies syntax highlighting based on JULIA_REPL_HIGHLIGHT and JULIA_REPL_OUTPUT_FORMAT settings.

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

    # Apply syntax highlighting to code (uses configured output format)
    highlighted_code = highlight_code(code)

    # Show code with julia> prompt (like REPL)
    code_lines = split(strip(highlighted_code), '\n')
    push!(parts, "julia> " * code_lines[1])
    for line in code_lines[2:end]
        push!(parts, "       " * line)
    end
    push!(parts, "")

    # Apply output truncation
    output = truncate_output(output, max_output)
    value_str = truncate_output(value_str, max_output)

    # Show printed output first (if any)
    if !isempty(strip(output))
        push!(parts, strip(output))
    end

    # Show result or error
    if error_str !== nothing
        push!(parts, truncate_stacktrace(error_str; max_frames=max_stackframes))
    else
        push!(parts, value_str)
    end

    # Append timing
    if elapsed !== nothing
        push!(parts, "")
        push!(parts, format_elapsed(elapsed))
    end

    return join(parts, "\n")
end
