#!/usr/bin/env bash
# scripts/check-plugins.sh — Verify the OpenCode config declares no invalid plugins
# Called by setup.sh via: source scripts/check-plugins.sh
# Exits with code 1 if any plugin entry is invalid.
#
# Background: OpenCode V2 rejects file:// plugin paths that point to a FILE —
# a configured plugin path must be a directory. This exact rejection removed
# the three legacy plugins (@razroo/opencode-model-fallback,
# @tarquinen/opencode-dcp, opencode-websearch-cited) during the V2 migration.

FAILED_PLUGINS=0

CONFIG_PATH="${1:-${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}}"

echo "  Checking OpenCode plugins (config: $CONFIG_PATH)..."

if [ ! -f "$CONFIG_PATH" ]; then
  echo "    ℹ️  config not found at $CONFIG_PATH — skipping plugin check"
  if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0
  else
    exit 0
  fi
fi

if ! command -v jq &>/dev/null; then
  echo "    ❌ jq — NOT FOUND (required to read plugin config)"
  if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 1
  else
    exit 1
  fi
fi

# Extract plugin entries. Accepts:
#   .plugin or .plugins
#   array-of-strings: ["file:///path", "npm-package-name"]
#   object form:      { "name": "path-or-{path,directory,...}" }
ENTRIES=$(jq -r '(.plugin // .plugins // empty)
  | if type == "array" then .[]
    else to_entries[] | (.value
      | if type == "string" then .
        else (.path // .directory // empty)
        end)
    end' "$CONFIG_PATH" 2>/dev/null)

check_plugin_entry() {
  local entry="$1"
  local path="$entry"

  # Strip file:// prefix if present
  case "$path" in
    file://*) path="${path#file://}" ;;
  esac

  if [ -d "$path" ]; then
    echo "    ✅ plugin directory found: $entry"
  elif [ -f "$path" ]; then
    echo "    ❌ plugin path must be a DIRECTORY, not a file: $entry"
    echo "       OpenCode V2 rejects it with: configured plugin path must be a directory"
    FAILED_PLUGINS=1
  elif [[ "$entry" != file://* && "$entry" != /* && "$entry" != .* ]]; then
    # Not a path — treat as an npm package name (not locally verifiable)
    echo "    ℹ️  plugin package (not verified locally): $entry"
  else
    # Container-absolute /opt/engine/<rest> paths resolve against the repo
    # checkout (engine/<rest>) when this script runs outside the container.
    local engine_dir resolved=""
    engine_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    case "$path" in
      /opt/engine/*)
        if [ -d "$engine_dir/${path#/opt/engine/}" ]; then
          resolved="$engine_dir/${path#/opt/engine/}"
        fi
        ;;
    esac
    if [ -n "$resolved" ]; then
      echo "    ✅ plugin directory found (repo checkout: $resolved): $entry"
    else
      echo "    ❌ plugin path does not exist: $path"
      FAILED_PLUGINS=1
    fi
  fi
}

if [ -z "$ENTRIES" ]; then
  echo "    ✅ no plugins configured — PASS (V2-native config)"
else
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    check_plugin_entry "$entry"
  done <<< "$ENTRIES"
fi

if [ "$FAILED_PLUGINS" -eq 1 ]; then
  echo ""
  echo "    ⛔ Invalid plugin entries found."
  echo "       V2 requires plugin paths to point to directories (or npm package names)."
fi

# Return FAILED_PLUGINS when sourced by setup.sh, exit when run standalone
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  return "$FAILED_PLUGINS"
else
  exit "$FAILED_PLUGINS"
fi
