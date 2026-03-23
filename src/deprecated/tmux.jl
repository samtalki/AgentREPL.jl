# deprecated/tmux.jl - REMOVED
#
# The tmux bidirectional REPL mode has been removed in v0.6.0.
# It had unfixable issues with marker pollution in the terminal output.
#
# Use distributed mode (default) with the log viewer for visual output:
#   - Set JULIA_REPL_VIEWER=auto
#   - Or manually: tail -f ~/.julia/logs/repl.log
