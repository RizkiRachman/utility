#!/usr/bin/env bash
# knowledge.sh - thin CLI adapter for the lean-ctx knowledge store (R2-14).
# The engine historically used the MCP tool name (ctx_knowledge) as if it
# were a CLI command; the deployed binary only ships the knowledge command.
# These wrappers target the deployed CLI and fall back to the legacy
# spelling so callers keep working across lean-ctx versions. They fail
# loudly (non-zero) so existing caller error handling stays effective.

# kb_remember VALUE KEY [CATEGORY] - store a fact (default: decisions)
kb_remember() {
    local value="$1" key="$2" category="${3:-decisions}"
    if lean-ctx knowledge --help >/dev/null 2>&1; then
        lean-ctx knowledge remember "$value" --category "$category" --key "$key"
    else
        lean-ctx ctx_knowledge remember --key "$key" --value "$value"
    fi
}

# kb_recall QUERY - semantic recall; the key text works well as a query
kb_recall() {
    local query="$1"
    if lean-ctx knowledge --help >/dev/null 2>&1; then
        lean-ctx knowledge recall "$query"
    else
        lean-ctx ctx_knowledge recall --query "$query"
    fi
}
