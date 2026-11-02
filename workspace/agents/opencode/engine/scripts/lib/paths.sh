#!/usr/bin/env bash
#
# lib/paths.sh — Project root and session path resolution
#
# The engine is deployed as a copy (engine/ -> /opt/engine/), so scripts cannot
# assume that their own parent directory is the project root. Runtime state
# (session/) lives with the project, not with the engine copy.
#
# Resolution order:
#   1. OPENCODE_PROJECT_ROOT override
#   2. current working directory (when it looks like the project)
#   3. engine root's parent (repo layout: <project>/engine/scripts)
#   4. well-known deployed locations (~/workspace/opencode, ~/workspace)
#   5. engine root (last resort)
#
# Sourced by scripts that mix engine assets with project-local session state.

resolve_project_root() {
    local engine_root="${1:-}"

    if [[ -n "${OPENCODE_PROJECT_ROOT:-}" && -d "${OPENCODE_PROJECT_ROOT}" ]]; then
        (cd "$OPENCODE_PROJECT_ROOT" && pwd)
        return 0
    fi

    if [[ -d "$PWD/session" || -d "$PWD/engine" || -f "$PWD/config/opencode.json" ]]; then
        printf '%s\n' "$PWD"
        return 0
    fi

    if [[ -n "$engine_root" ]]; then
        local parent
        parent="$(cd "$engine_root/.." 2>/dev/null && pwd || true)"
        if [[ -n "$parent" && ( -d "$parent/session" || -d "$parent/engine" || -f "$parent/config/opencode.json" ) ]]; then
            printf '%s\n' "$parent"
            return 0
        fi
    fi

    local candidate
    for candidate in \
        "$HOME/workspace/opencode" \
        "$HOME/workspace" \
        "/home/node/workspace/opencode" \
        "/home/node/workspace"
    do
        if [[ -d "$candidate/session" || -d "$candidate/engine" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    printf '%s\n' "${engine_root:-$PWD}"
}

resolve_session_dir() {
    local project_root="$1"
    printf '%s\n' "$project_root/session"
}

resolve_opencode_config() {
    local project_root="$1"
    local engine_root="${2:-}"
    local candidate
    for candidate in \
        "${OPENCODE_CONFIG:-}" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json" \
        "$project_root/config/opencode.json" \
        "$project_root/opencode.json" \
        "$engine_root/opencode.json.template"
    do
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}
