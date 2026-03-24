---
name: julia-plot
description: Use when the user asks to "plot", "visualize", "chart", "graph data", "scatter plot", "histogram", "heatmap", "bar chart", or wants to see data visually in the Julia REPL. Also trigger for exploratory data analysis, distribution analysis, time series inspection, or when visual output would help understand numerical results.
version: 0.6.0
---

# Plotting with UnicodePlots.jl

UnicodePlots renders terminal-native plots directly in the REPL tool output. Plots use Unicode Braille characters with ANSI colors — no GUI, no file export, no external viewer needed. The plot appears inline in the eval response.

## Setup

If UnicodePlots is not loaded in the session:

```
pkg(action="add", packages="UnicodePlots")
```

Then in eval:
```julia
using UnicodePlots
```

UnicodePlots stays loaded across evals — you only pay the import cost once.

## Plot Types

### Line plots
```julia
lineplot(sin, -2π, 2π, title="Sine Wave", name="sin(x)")
lineplot!(ans, cos, -2π, 2π, name="cos(x)")  # overlay on previous plot
```

### Scatter plots
```julia
scatterplot(x, y, title="My Data", xlabel="x", ylabel="y")
```

### Histograms
```julia
histogram(randn(10000), nbins=40, title="Normal Distribution")
```

### Bar charts
```julia
barplot(["Julia", "Python", "Rust"], [95, 78, 88], title="Scores")
```

### Heatmaps
```julia
heatmap(rand(20, 40), title="Random Heatmap")
```

### Box plots
```julia
boxplot(["A", "B", "C"], [randn(100), randn(100) .+ 1, randn(100) .* 2])
```

### Density plots
```julia
densityplot(randn(10000), randn(10000), title="2D Density")
```

### Staircase / step plots
```julia
stairs([1, 2, 4, 7, 8], [1, 3, 4, 2, 7])
```

### Contour plots
```julia
contourplot(-3:0.1:3, -3:0.1:3, (x, y) -> exp(-(x^2 + y^2)))
```

## Tips

- **Overlaying**: Use `!` variants (`lineplot!`, `scatterplot!`) to add series to an existing plot. Pass the previous plot as the first argument or use `ans`.
- **Size**: Default is 15 rows x 40 cols. Override with `height=` and `width=` kwargs.
- **Colors**: Plots render with ANSI colors automatically. Use `color=:red` etc. for specific series colors.
- **Compact mode**: Use `compact=true` to reduce margins when space is tight.
- **Labels**: All plots support `title`, `xlabel`, `ylabel`, `name` (legend entry).
- **Unicode output**: Plots use Braille characters for high resolution — they work in any Unicode terminal.

## Displaying Plots

After calling eval with plotting code, **always paste the plot output into your response** inside a plain code block. MCP tool results are collapsed by default in Claude Code — the user cannot see the plot unless you include it in your response text. This applies to all visual output: plots, heatmaps, density maps, bar charts, etc.
