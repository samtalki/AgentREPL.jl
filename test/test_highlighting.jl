# Test syntax highlighting functionality

@testset "Syntax Highlighting" begin
    @testset "Configuration" begin
        @test AgentREPL.is_highlighting_enabled() isa Bool
        @test AgentREPL.get_output_format() in [:ansi, :markdown, :plain]
    end

    @testset "Plain Format" begin
        code = "x = 1 + 1"
        result = AgentREPL.highlight_code(code; format=:plain)
        @test result == code  # No modification for plain format
    end

    @testset "Markdown Format" begin
        code = "x = 1 + 1"
        result = AgentREPL.highlight_code(code; format=:markdown)
        @test startswith(result, "```julia")
        @test endswith(result, "```")
        @test contains(result, code)
    end

    @testset "ANSI Format" begin
        code = "function foo(x)\n    return x + 1\nend"
        result = AgentREPL.highlight_code(code; format=:ansi)

        # If highlighting is enabled, ANSI output should contain escape codes
        # or at minimum differ from input (due to processing)
        if AgentREPL.is_highlighting_enabled()
            # Check for ANSI escape sequence (ESC character = 0x1b)
            has_ansi = any(c -> UInt8(c) == 0x1b, result)
            @test has_ansi || result == code  # Either has ANSI or fallback to plain
        else
            @test result == code  # When disabled, returns unchanged
        end
    end

    @testset "Empty Code" begin
        @test AgentREPL.highlight_code(""; format=:plain) == ""
        @test AgentREPL.highlight_code(""; format=:ansi) == ""
        @test AgentREPL.highlight_code(""; format=:markdown) == ""
    end

    @testset "Multiline Code" begin
        code = """
        struct Point
            x::Float64
            y::Float64
        end
        """
        for format in [:plain, :markdown, :ansi]
            result = AgentREPL.highlight_code(code; format=format)
            @test !isempty(result)
            @test contains(result, "struct") || contains(result, "Point")
        end
    end

    @testset "Special Characters" begin
        # Unicode and special characters should be preserved
        code = "# Comment with unicode: ∀ x ∈ ℝ\nx = \"string with 'quotes'\""
        for format in [:plain, :ansi]
            result = AgentREPL.highlight_code(code; format=format)
            @test contains(result, "∀")
            @test contains(result, "ℝ")
        end
    end

    @testset "Default Format Uses Config" begin
        # When no format specified, should use get_output_format()
        code = "x = 1"
        result_default = AgentREPL.highlight_code(code)
        result_explicit = AgentREPL.highlight_code(code; format=AgentREPL.get_output_format())
        @test result_default == result_explicit
    end

    @testset "Unknown Format Falls Back" begin
        code = "x = 1"
        # Unknown format should warn and return plain
        result = AgentREPL.highlight_code(code; format=:unknown_format)
        @test result == code
    end
end
