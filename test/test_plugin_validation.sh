#!/usr/bin/env bash
#
# AgentREPL.jl - Plugin Structure Validation
#
# Validates that the Claude Code plugin has all required files and structure.
# No API key needed.
#
# Usage:
#   bash test/test_plugin_validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PLUGIN_DIR="$REPO_DIR/claude-plugin"

PASS=0
FAIL=0

check() {
    local name="$1" condition="$2"
    printf "CHECK: %-50s" "$name"
    if eval "$condition"; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== AgentREPL.jl Plugin Validation ==="
echo "Plugin: $PLUGIN_DIR"
echo ""

# --- Required files exist ---
check "plugin.json exists" \
    "[ -f '$PLUGIN_DIR/.claude-plugin/plugin.json' ]"

check ".mcp.json exists" \
    "[ -f '$PLUGIN_DIR/.mcp.json' ]"

check "hooks.json exists" \
    "[ -f '$PLUGIN_DIR/hooks/hooks.json' ]"

check "README.md exists" \
    "[ -f '$PLUGIN_DIR/README.md' ]"

# --- All skill directories have SKILL.md ---
for dir in "$PLUGIN_DIR"/skills/*/; do
    name=$(basename "$dir")
    check "skill '$name' has SKILL.md" \
        "[ -f '$dir/SKILL.md' ]"
done

# --- plugin.json has required fields ---
if command -v python3 &>/dev/null; then
    for field in name version description; do
        check "plugin.json has '$field' field" \
            "python3 -c \"import json; d=json.load(open('$PLUGIN_DIR/.claude-plugin/plugin.json')); assert '$field' in d\" 2>/dev/null"
    done
elif command -v jq &>/dev/null; then
    for field in name version description; do
        check "plugin.json has '$field' field" \
            "jq -e '.$field' '$PLUGIN_DIR/.claude-plugin/plugin.json' >/dev/null 2>&1"
    done
else
    echo "NOTE: python3 or jq not found, skipping JSON field validation"
fi

# --- .mcp.json references the server script ---
check ".mcp.json references julia-repl-server" \
    "grep -q 'julia-repl-server' '$PLUGIN_DIR/.mcp.json'"

# --- hooks.json has expected hooks ---
check "hooks.json has PreToolUse hook" \
    "grep -q 'PreToolUse' '$PLUGIN_DIR/hooks/hooks.json'"

check "hooks.json has PostToolUse hook" \
    "grep -q 'PostToolUse' '$PLUGIN_DIR/hooks/hooks.json'"

# --- Server entry point exists ---
check "bin/julia-repl-server exists" \
    "[ -f '$REPO_DIR/bin/julia-repl-server' ]"

# --- Project.toml exists and has name ---
check "Project.toml exists" \
    "[ -f '$REPO_DIR/Project.toml' ]"

check "Project.toml names AgentREPL" \
    "grep -q 'name = \"AgentREPL\"' '$REPO_DIR/Project.toml'"

# --- Version consistency ---
if command -v python3 &>/dev/null; then
    PLUGIN_VERSION=$(python3 -c "import json; print(json.load(open('$PLUGIN_DIR/.claude-plugin/plugin.json'))['version'])" 2>/dev/null || echo "")
    PROJECT_VERSION=$(grep '^version' "$REPO_DIR/Project.toml" | sed 's/.*"\(.*\)"/\1/' || echo "")
    check "version match (plugin=$PLUGIN_VERSION, Project.toml=$PROJECT_VERSION)" \
        "[ '$PLUGIN_VERSION' = '$PROJECT_VERSION' ]"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
