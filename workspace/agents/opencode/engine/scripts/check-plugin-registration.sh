#!/usr/bin/env bash
# check-plugin-registration.sh — verify the guard plugin is registered in the
# live OpenCode config and that its deployed files are present and syntactically
# valid. Read-only: agents must never edit opencode.json directly.
set -uo pipefail
CONFIG="${1:-${HOME}/.config/opencode/opencode.json}"
PLUGIN="${2:-/opt/engine/plugins/opencode-workflow-guard}"
EXPECTED="${PLUGIN_REGISTERED_PATH:-$PLUGIN}"
config_found=false; registered=false; files_ok=true; syntax_ok=true; status=""
[[ -f "$CONFIG" ]] && config_found=true
if [[ "$config_found" == true ]]; then
  registered=$(jq -e --arg p "$EXPECTED" '.plugins // [] | index($p) != null' "$CONFIG" 2>/dev/null) || registered=false
fi
for f in guard.js index.js package.json; do
  [[ -f "$PLUGIN/$f" ]] || files_ok=false
done
node_available=true
command -v node >/dev/null 2>&1 || node_available=false
if [[ "$files_ok" == true && "$node_available" == true ]]; then
  node --check "$PLUGIN/guard.js" >/dev/null 2>&1 || syntax_ok=false
  node --check "$PLUGIN/index.js" >/dev/null 2>&1 || syntax_ok=false
fi
if [[ "$config_found" != true ]]; then status="config_missing"; rc=2
elif [[ "$registered" != true ]]; then status="not_registered"; rc=1
elif [[ "$files_ok" != true ]]; then status="files_missing"; rc=1
elif [[ "$node_available" != true ]]; then status="syntax_unverified"; syntax_ok=false; rc=1
elif [[ "$syntax_ok" != true ]]; then status="syntax_invalid"; rc=1
else status="registered"; rc=0; fi
printf '{"config":"%s","config_found":%s,"plugin":"%s","registered":%s,"files_ok":%s,"syntax_ok":%s,"node_available":%s,"status":"%s"}\n' \
  "$CONFIG" "$config_found" "$PLUGIN" "$registered" "$files_ok" "$syntax_ok" "$node_available" "$status"
exit "$rc"
