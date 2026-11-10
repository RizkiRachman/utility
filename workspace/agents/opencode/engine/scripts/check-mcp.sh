#!/usr/bin/env bash
# scripts/check-mcp.sh — Verify MCP tools are installed
# Called by setup.sh via: source scripts/check-mcp.sh
# Exits with code 1 if any MANDATORY tool is missing.

FAILED_MCP=0

echo "  Checking MCP tools..."

# lean-ctx — MANDATORY
if command -v lean-ctx &>/dev/null; then
  echo "    ✅ lean-ctx — found"
else
  echo "    ❌ lean-ctx — NOT FOUND (MANDATORY)"
  echo "       Install: https://github.com/yvgude/lean-ctx"
  FAILED_MCP=1
fi


# context7 — OPTIONAL
if command -v context7-mcp &>/dev/null || command -v context7 &>/dev/null || npm list -g @upstash/context7-mcp &>/dev/null 2>&1; then
  echo "    ✅ context7-mcp — found"
else
  echo "    ℹ️  context7-mcp — not found (OPTIONAL — docs lookup only)"
  echo "       Install: npm install -g @upstash/context7-mcp"
fi

if [ "$FAILED_MCP" -eq 1 ]; then
  echo ""
  echo "    ⛔ Some MANDATORY MCP tools are missing."
  echo "       Install them and re-run setup.sh."
fi

# Return FAILED_MCP when sourced by setup.sh, exit when run standalone
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  return "$FAILED_MCP"
else
  exit "$FAILED_MCP"
fi
