#!/usr/bin/env bash
# T14-plugin-registration.sh — guard registration is checked, not assumed.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$SCRIPT_DIR/../check-plugin-registration.sh"
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/plugin"
printf 'export const x = 1;\n' > "$D/plugin/guard.js"
printf 'export const y = 2;\n' > "$D/plugin/index.js"
printf '{"name":"workflow-guard"}\n' > "$D/plugin/package.json"
printf '{"plugins":["%s"]}' "$D/plugin" > "$D/ok.json"
printf '{"plugins":[]}' > "$D/empty.json"
pass=0; fail=0
run() { bash "$S" "$1" "$D/plugin" 2>/dev/null; return $?; }
check() {
  local label="$1" cfg="$2" key="$3" want="$4" out rc
  out=$(run "$cfg"); rc=$?
  got=$(printf '%s\n' "$out" | jq -r "$key")
  [[ "$got" == "$want" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $label: $key expected $want, got $got"; }
  echo "$rc" > "$D/last_rc"
}
check "registered" "$D/ok.json" ".status" "registered"
[[ "$(cat "$D/last_rc")" == "0" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL registered rc"; }
check "not registered" "$D/empty.json" ".status" "not_registered"
[[ "$(cat "$D/last_rc")" == "1" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL not registered rc"; }
check "config missing" "$D/nope.json" ".status" "config_missing"
[[ "$(cat "$D/last_rc")" == "2" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL missing rc"; }
rm "$D/plugin/index.js"
check "files missing" "$D/ok.json" ".status" "files_missing"
echo "T14 plugin registration: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
