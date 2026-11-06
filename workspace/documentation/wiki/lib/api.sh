#!/usr/bin/env bash
# lib/api.sh — Confluence Cloud REST API client (bash + curl wrappers).
#
# Auth: HTTP Basic with CONFLUENCE_EMAIL + CONFLUENCE_TOKEN.
# The token lives in the environment only: never echoed, never logged,
# never written to any file by this library. Note: the token is visible in
# the process list for the lifetime of each curl call (accepted trade-off
# for a zero-dependency CLI; no token ever lands on disk).

API_BASE_URL="${CONFLUENCE_BASE_URL:-https://infinitium.atlassian.net/wiki}"
API_EMAIL="${CONFLUENCE_EMAIL:-rizki.rachman@infinitium.com}"
API_LAST_STATUS="000"

api_require_token() {
  if [[ -z "${CONFLUENCE_TOKEN:-}" ]]; then
    echo "ERROR: CONFLUENCE_TOKEN is not set (required for this operation)." >&2
    echo "Create an API token at https://id.atlassian.com/manage-profile/security/api-tokens" >&2
    echo "then export it for this shell only: export CONFLUENCE_TOKEN='<token>' (never commit it)." >&2
    return 1
  fi
  return 0
}

# api_curl METHOD PATH [BODY_FILE]
#   Body goes to stdout; HTTP status lands in API_LAST_STATUS.
#   Returns 1 on network failure (curl-level), with status forced to 000.
api_curl() {
  local method="$1" path="$2" body_file="${3:-}" tmp
  tmp="$(mktemp)"
  local args=(
    -sS --max-time 120
    -X "$method"
    -u "$API_EMAIL:${CONFLUENCE_TOKEN:-}"
    -H 'Accept: application/json'
    -o "$tmp"
    -w '%{http_code}'
    "$API_BASE_URL$path"
  )
  if [[ -n "$body_file" ]]; then
    args+=(-H 'Content-Type: application/json' --data-binary @"$body_file")
  fi
  if ! API_LAST_STATUS="$(curl "${args[@]}")"; then
    rm -f "$tmp"
    echo "ERROR: curl network failure talking to $API_BASE_URL$path" >&2
    API_LAST_STATUS="000"
    return 1
  fi
  cat "$tmp"
  rm -f "$tmp"
}

# json_field JSON_STRING DOT.PATH → prints value (may be empty)
json_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    cur = json.loads(sys.argv[1])
except Exception:
    raise SystemExit
for k in sys.argv[2].split('.'):
    try:
        cur = cur[int(k)] if isinstance(cur, list) else cur.get(k)
    except Exception:
        cur = None
    if cur is None:
        break
if cur is None:
    print("")
elif isinstance(cur, bool):
    print("true" if cur else "false")
elif isinstance(cur, (dict, list)):
    print(json.dumps(cur))
else:
    print(cur)
PY
}

# json_quote STRING → prints STRING as a JSON string literal
json_quote() {
  python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
}

# api_build_create_payload TITLE PARENT_ID SPACE XHTML_FILE OUT_FILE
api_build_create_payload() {
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json, sys
title, parent, space, src, dst = sys.argv[1:6]
body = open(src, encoding="utf-8").read()
payload = {
    "type": "page",
    "title": title,
    "space": {"key": space},
    "ancestors": [{"id": parent}],
    "body": {"storage": {"value": body, "representation": "storage"}},
}
open(dst, "w", encoding="utf-8").write(json.dumps(payload))
PY
}

# api_build_update_payload PAGE_ID TITLE NEXT_VERSION XHTML_FILE OUT_FILE
api_build_update_payload() {
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json, sys
page_id, title, version, src, dst = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
body = open(src, encoding="utf-8").read()
payload = {
    "id": page_id,
    "type": "page",
    "title": title,
    "version": {"number": version},
    "body": {"storage": {"value": body, "representation": "storage"}},
}
open(dst, "w", encoding="utf-8").write(json.dumps(payload))
PY
}
