# formatting.jl - Result formatting and stacktrace truncation

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
    format_result(code::String, value_str::String, output::String, error_str::Union{String,Nothing}) -> String

Format the evaluation result for display in REPL style.
Shows the code with `julia>` prompt followed by output and result.
Applies syntax highlighting based on JULIA_REPL_HIGHLIGHT and JULIA_REPL_OUTPUT_FORMAT settings.
"""
function format_result(code::String, value_str::String, output::String, error_str::Union{String,Nothing})
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

    # Show printed output first (if any)
    if !isempty(strip(output))
        push!(parts, strip(output))
    end

    # Show result or error
    if error_str !== nothing
        push!(parts, truncate_stacktrace(error_str))
    else
        push!(parts, value_str)
    end

    return join(parts, "\n")
end
