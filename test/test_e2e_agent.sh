#!/usr/bin/env bash
#
# AgentREPL.jl - Claude Code Agent E2E Tests
#
# Tests that a Claude Code agent can install the plugin and use all tools.
# Requires: claude CLI with API key configured.
#
# Usage:
#   bash test/test_e2e_agent.sh
#
# Each test is an independent `claude -p` invocation for isolation.
# Uses --dangerously-skip-permissions for automation (sandboxed environments only).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PLUGIN_DIR="$REPO_DIR/claude-plugin"

PASS=0
FAIL=0
SKIP=0

# Check prerequisites
if ! command -v claude &>/dev/null; then
    echo "ERROR: 'claude' CLI not found in PATH. Install Claude Code first."
    exit 1
fi

# Check if API key is available (claude will fail without it)
if ! claude -p "echo test" &>/dev/null 2>&1; then
    echo "SKIP: Claude CLI not configured or no API key. Skipping agent E2E tests."
    exit 0
fi

run_test() {
    local name="$1" prompt="$2" expected="$3"
    printf "TEST: %-40s" "$name"

    local output
    output=$(claude -p \
        --plugin-dir "$PLUGIN_DIR" \
        --dangerously-skip-permissions \
        --model sonnet \
        --max-budget-usd 0.50 \
        --no-session-persistence \
        --bare \
        "$prompt" 2>/dev/null) || true

    if echo "$output" | grep -qiE "$expected"; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL"
        echo "  Expected pattern: $expected"
        echo "  Got (first 300 chars): ${output:0:300}"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== AgentREPL.jl Agent E2E Tests ==="
echo "Plugin: $PLUGIN_DIR"
echo ""

# Test 1: eval basic arithmetic
run_test "eval-arithmetic" \
    "Use the Julia eval MCP tool to compute 6 * 7. Show me only the numeric result." \
    "42"

# Test 2: eval variable persistence (two calls in one conversation)
run_test "eval-persistence" \
    "Use the Julia eval tool to run: _e2e_var = 123. Then in a second eval call, run: _e2e_var + 1. Tell me the final result." \
    "124"

# Test 3: info tool
run_test "info" \
    "Use the Julia info MCP tool and tell me the Julia version number." \
    "Julia|julia|[0-9]+\.[0-9]+"

# Test 4: session management
run_test "session-create-list" \
    "Use the Julia session tool to create a session named 'e2e-test', then list all sessions. Show me the list." \
    "e2e-test"

# Test 5: reset clears state
run_test "reset-clears" \
    "Use the Julia eval tool to set _r = 1. Then use the Julia reset tool. Then try to eval _r. Tell me if _r is defined or not." \
    "UndefVarError|not defined|undefined|cleared"

# Test 6: pkg status
run_test "pkg-status" \
    "Use the Julia pkg tool with action 'status' and show me the output." \
    "Status|status|Project|package"

# Test 7: revise status
run_test "revise-status" \
    "Use the Julia revise tool with action 'status' and tell me whether Revise.jl is loaded." \
    "Revise|revise|loaded|available"

echo ""
echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
