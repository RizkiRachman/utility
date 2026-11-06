#!/usr/bin/env bash
# tests/smoke.sh — READ-ONLY Confluence API smoke test.
# Performs zero writes. Auto-skips when CONFLUENCE_TOKEN is not set.
#
# Checks:
#   1. Root folder 4125949974 is reachable and titled 'Local Toolkit Setup'.
#   2. Root folder ancestors endpoint works.
#   3. child/folder listing works (init relies on it).
#   4. child/page listing works (init relies on it).
#   5. Known child folder 4157603973 ('CI/CD') sits inside the root subtree
#      (validates the hard-boundary assumption).
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=../lib/api.sh
source "$ROOT/lib/api.sh"

CHECKS=0
pass() { echo "PASS: $1"; CHECKS=$((CHECKS + 1)); }
fail() { echo "FAIL: $1"; [[ -n "${2:-}" ]] && echo "      $2"; exit 1; }

if [[ -z "${CONFLUENCE_TOKEN:-}" ]]; then
  echo "SKIP: CONFLUENCE_TOKEN not set — read-only smoke test skipped (exit 0)."
  exit 0
fi

ROOT_ID="4125949974"
CICD_ID="4157603973"

# 1. root folder
if ! body="$(api_curl GET "/rest/api/content/$ROOT_ID")"; then
  fail "GET root folder" "curl network error"
fi
[[ "$API_LAST_STATUS" == "200" ]] || fail "GET root folder" "HTTP $API_LAST_STATUS"
title="$(json_field "$body" title)"
[[ "$title" == "Local Toolkit Setup" ]] || fail "root folder title" "expected 'Local Toolkit Setup', got '$title'"
pass "GET root folder returns 'Local Toolkit Setup'"

# 2. root ancestors
if ! body="$(api_curl GET "/rest/api/content/$ROOT_ID?expand=ancestors")"; then
  fail "GET root ancestors" "curl network error"
fi
[[ "$API_LAST_STATUS" == "200" ]] || fail "GET root ancestors" "HTTP $API_LAST_STATUS"
json_field "$body" id >/dev/null || fail "root ancestors JSON" "unparseable response"
pass "GET root folder with expand=ancestors works"

# 3. child/folder listing
if ! body="$(api_curl GET "/rest/api/content/$ROOT_ID/child/folder?limit=50")"; then
  fail "GET child/folder" "curl network error"
fi
[[ "$API_LAST_STATUS" == "200" ]] || fail "GET child/folder" "HTTP $API_LAST_STATUS"
n_folders="$(printf '%s' "$body" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("results", [])))')" \
  || fail "GET child/folder JSON" "unparseable response"
pass "GET child/folder works ($n_folders folders under root)"

# 4. child/page listing
if ! body="$(api_curl GET "/rest/api/content/$ROOT_ID/child/page?limit=50")"; then
  fail "GET child/page" "curl network error"
fi
[[ "$API_LAST_STATUS" == "200" ]] || fail "GET child/page" "HTTP $API_LAST_STATUS"
n_pages="$(printf '%s' "$body" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("results", [])))')" \
  || fail "GET child/page JSON" "unparseable response"
pass "GET child/page works ($n_pages direct child pages under root)"

# 5. CI/CD folder is a descendant of the boundary root
if ! body="$(api_curl GET "/rest/api/content/$CICD_ID?expand=ancestors")"; then
  fail "GET CI/CD folder" "curl network error"
fi
[[ "$API_LAST_STATUS" == "200" ]] || fail "GET CI/CD folder" "HTTP $API_LAST_STATUS"
ancestor_ids="$(printf '%s' "$body" | python3 -c 'import json,sys; print(",".join(str(a.get("id")) for a in json.load(sys.stdin).get("ancestors", [])))')" \
  || fail "CI/CD ancestors JSON" "unparseable response"
[[",$ancestor_ids," == *",$ROOT_ID,"*]] || fail "boundary assumption" "CI/CD $CICD_ID ancestors [$ancestor_ids] do not include root $ROOT_ID"
pass "CI/CD folder $CICD_ID confirmed inside root subtree"

echo
echo "smoke: $CHECKS checks passed (read-only, nothing written)"
