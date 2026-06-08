---
name: julia-plot
description: Activates when user asks to plot, chart, or visualize data in the Julia REPL.
version: 0.7.1
---

# Julia Plotting — UnicodePlots

For terminal-native plots in the Julia REPL, use UnicodePlots.jl:

```
pkg(action="add", packages="UnicodePlots")
```
```julia
using UnicodePlots
```

Available: `lineplot`, `scatterplot`, `histogram`, `barplot`, `heatmap`, `boxplot`, `densityplot`, `stairs`, `contourplot`. Use `!` variants (e.g., `lineplot!`) to overlay series on an existing plot. Control size with `height` and `width` kwargs.
