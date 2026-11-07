#!/usr/bin/env bash
# publish.sh — markdown-first Confluence authoring CLI (space NPG).
#
# Usage:
#   ./publish.sh <file.md>            Dry-run: gates + plan + storage preview. No writes.
#   ./publish.sh <file.md> --publish  All gates, then create/update via Confluence API.
#   ./publish.sh init                 Fetch + print folder tree under root folder 4125949974.
#
# HARD BOUNDARY: writes are allowed ONLY under Confluence folder 4125949974
# ("Local Toolkit Setup") or its descendants. The scope gate verifies the
# frontmatter parent against that subtree before anything is written; anything
# outside it is refused with zero writes.
#
# Auth: HTTP Basic, CONFLUENCE_EMAIL + CONFLUENCE_TOKEN env vars. The token is
# never echoed or written to any file.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$ROOT/lib"
MAPPINGS_FILE="${MAPPINGS_FILE:-$ROOT/mappings.json}"
TMP_FILES=()
REL_PATH=""
TMP_BODY=""

EX_USAGE=2
EX_SCOPE=3
EX_FRONTMATTER=4
EX_LINT=5
EX_CONFLICT=6
EX_API=7
EX_DEPS=8

# shellcheck source=lib/api.sh
source "$LIB/api.sh"

add_tmp() { TMP_FILES+=("$1"); }

cleanup() {
  if ((${#TMP_FILES[@]})); then
    rm -f "${TMP_FILES[@]}"
  fi
  return 0
}

die() {
  local code="$1" msg="$2"
  echo "ERROR: $msg" >&2
  exit "$code"
}

usage() {
  cat <<'EOF'
publish.sh — markdown-first Confluence authoring (space NPG, boundary folder 4125949974)

Usage:
  ./publish.sh <file.md>            Dry-run: frontmatter, scope, humanizer lint, plan + storage preview. No writes.
  ./publish.sh <file.md> --publish  Run all gates, then create/update the page via the Confluence API.
  ./publish.sh init                 Fetch and print the folder tree under 4125949974 (caches scope ancestry).
  ./publish.sh --help               This help.

Exit codes:
  0 success | 2 usage | 3 scope refusal / fail-closed | 4 frontmatter | 5 hard lint
  6 version conflict | 7 API/network | 8 missing tool or token

Env:
  CONFLUENCE_TOKEN     required for anything touching the API (never commit it)
  CONFLUENCE_EMAIL     default rizki.rachman@infinitium.com
  CONFLUENCE_BASE_URL  default https://infinitium.atlassian.net/wiki
EOF
}

deps_check() {
  local miss=()
  command -v python3 >/dev/null 2>&1 || miss+=(python3)
  command -v curl >/dev/null 2>&1 || miss+=(curl)
  if ((${#miss[@]})); then
    die "$EX_DEPS" "missing required tools: ${miss[*]} (python3 and curl must be installed)"
  fi
  return 0
}

# ---------- mappings.json helpers (python3 stdlib for JSON) ----------

mappings_field() { # FIELD → value or empty
  python3 - "$MAPPINGS_FILE" "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    d = {}
v = d.get(sys.argv[2], "")
print(v if isinstance(v, str) else json.dumps(v))
PY
}

scope_cache_field() { # ID FIELD → value or empty
  python3 - "$MAPPINGS_FILE" "$1" "$2" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    d = {}
e = d.get("scope_cache", {}).get(sys.argv[2])
if not isinstance(e, dict):
    print("")
else:
    v = e.get(sys.argv[3], "")
    if isinstance(v, bool):
        v = "true" if v else "false"
    print(v)
PY
}

page_field() { # REL_PATH FIELD → value or empty
  python3 - "$MAPPINGS_FILE" "$1" "$2" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    d = {}
v = d.get("pages", {}).get(sys.argv[2], {}).get(sys.argv[3])
print("" if v is None else v)
PY
}

lookup_parent_title() { # ID → title or empty
  python3 - "$MAPPINGS_FILE" "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    d = {}
pid = sys.argv[2]
for sect in ("known_folders", "discovered_pages", "scope_cache"):
    e = d.get(sect, {}).get(pid)
    if isinstance(e, dict) and e.get("title"):
        print(e["title"])
        break
else:
    print("")
PY
}

mappings_update() { # OP ARGS... ; ops: page <rel> <json-entry> | bulk <json-entry>
  python3 - "$MAPPINGS_FILE" "$@" <<'PY'
import datetime, json, os, sys, tempfile

mpath, op = sys.argv[1], sys.argv[2]
data = json.load(open(mpath, encoding="utf-8"))
if op == "page":
    key = sys.argv[3]
    entry = json.loads(sys.argv[4])
    slot = data.setdefault("pages", {}).setdefault(key, {})
    for k, v in entry.items():
        if v is None:
            slot.pop(k, None)
        else:
            slot[k] = v
elif op == "bulk":
    entry = json.loads(sys.argv[3])
    for k, v in entry.items():
        if isinstance(v, dict):
            data.setdefault(k, {}).update(v)
        else:
            data[k] = v
else:
    raise SystemExit("unknown mappings_update op: " + op)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(mpath) or ".")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, mpath)
PY
}

# ---------- gate 2: scope guard ----------

scope_refuse() {
  echo "REFUSED: parent $1 is outside the publish boundary — $2." >&2
  echo "Writes are allowed ONLY under 4125949974 ('Local Toolkit Setup') or its descendants." >&2
  echo "No writes were performed. Pick an in-scope parent via './publish.sh init'." >&2
  exit "$EX_SCOPE"
}

verify_scope() { # PARENT_ID MODE(dry|live) → rc 0 in scope, exit 3 refused
  local pid="$1" mode="$2" root cached body verdict flag title anc
  root="$(mappings_field root_folder_id)"
  if [[ "$pid" == "$root" ]]; then
    echo "scope: parent $pid is the boundary root folder — inside boundary"
    return 0
  fi
  cached="$(scope_cache_field "$pid" in_scope)"
  if [[ "$mode" == "dry" && -n "$cached" ]]; then
    if [[ "$cached" == "true" ]]; then
      echo "scope: parent $pid inside boundary (cached ancestry, verified $(scope_cache_field "$pid" verified_at))"
      return 0
    fi
    scope_refuse "$pid" "cached ancestry shows it outside the boundary"
  fi
  # Live verification: mandatory for --publish; fallback for uncached dry-runs.
  if ! api_require_token; then
    echo "ERROR: scope for parent $pid is unverified and CONFLUENCE_TOKEN is unset (fail-closed)." >&2
    echo "Run './publish.sh init' once with a token to cache the folder tree, or export CONFLUENCE_TOKEN." >&2
    exit "$EX_SCOPE"
  fi
  if ! body="$(api_curl GET "/rest/api/content/$pid?expand=ancestors")"; then
    die "$EX_SCOPE" "network failure during scope check for parent $pid — refusing (fail closed)"
  fi
  if [[ "$(cat "$API_STATUS_FILE" 2>/dev/null || printf 000)" != "200" ]]; then
    die "$EX_SCOPE" "scope check got HTTP $(cat "$API_STATUS_FILE" 2>/dev/null || printf 000) for parent $pid — refusing (fail closed)"
  fi
  if ! verdict="$(printf '%s' "$body" | python3 -c "$(cat <<'PYSCOPE'
import datetime, json, os, sys, tempfile

d = json.load(sys.stdin)
pid, root, mpath = sys.argv[1], sys.argv[2], sys.argv[3]
chain = [str(d.get("id", pid))] + [str(a.get("id", "")) for a in d.get("ancestors", [])]
ancestors = [a for a in chain[1:] if a]
in_scope = root in chain
title = d.get("title", "")
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
try:
    data = json.load(open(mpath, encoding="utf-8"))
except Exception:
    data = {}
data.setdefault("scope_cache", {})[pid] = {
    "in_scope": in_scope,
    "ancestors": ancestors,
    "title": title,
    "verified_at": now,
}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(mpath) or ".")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, mpath)
print(("IN" if in_scope else "OUT") + "\t" + title + "\t" + ",".join(ancestors))
PYSCOPE
)" "$pid" "$root" "$MAPPINGS_FILE")"; then
    die "$EX_SCOPE" "could not evaluate scope response for parent $pid — refusing (fail closed)"
  fi
  IFS=$'\t' read -r flag title anc <<<"$verdict"
  if [[ "$flag" == "IN" ]]; then
    echo "scope: parent $pid ('$title') is inside the boundary (ancestor chain: ${anc:-none})"
    return 0
  fi
  scope_refuse "$pid" "ancestor chain (${anc:-none}) does not include root $root"
}

# ---------- gate 1: frontmatter ----------

trim() {
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

parse_frontmatter() { # FILE → sets FM_TITLE, FM_PARENT, FM_ID, TMP_BODY
  local file="$1" first_line close line key val
  first_line="$(head -n 1 "$file")"
  if [[ "$first_line" != "---" ]]; then
    echo "frontmatter: missing — the file must begin with a '---' line (title, parent, optional confluence-id)" >&2
    return "$EX_FRONTMATTER"
  fi
  close="$(awk 'NR>1 && /^---[[:space:]]*$/{print NR; exit}' "$file")"
  if [[ -z "$close" ]]; then
    echo "frontmatter: closing '---' line not found" >&2
    return "$EX_FRONTMATTER"
  fi
  if ((close > 61)); then
    echo "frontmatter: more than 60 lines — refusing to parse" >&2
    return "$EX_FRONTMATTER"
  fi
  FM_TITLE=""
  FM_PARENT=""
  FM_ID=""
  while IFS= read -r line; do
    [[ "$line" == *:* ]] || continue
    key="$(trim "${line%%:*}")"
    val="$(trim "${line#*:}")"
    val="${val%\"}"
    val="${val#\"}"
    val="${val%\'}"
    val="${val#\'}"
    case "$key" in
      title) FM_TITLE="$val" ;;
      parent) FM_PARENT="$val" ;;
      confluence-id) FM_ID="$val" ;;
      *) : ;; # extra fields are ignored
    esac
  done < <(sed -n "2,$((close - 1))p" "$file")
  if [[ -z "$FM_TITLE" ]]; then
    echo "frontmatter: 'title' missing or empty" >&2
    return "$EX_FRONTMATTER"
  fi
  if [[ -z "$FM_PARENT" ]]; then
    echo "frontmatter: 'parent' missing or empty" >&2
    return "$EX_FRONTMATTER"
  fi
  FM_ID="${FM_ID:-}" # absent or empty → CREATE
  TMP_BODY="$(mktemp)"
  add_tmp "$TMP_BODY"
  sed -n "$((close + 1)),\$p" "$file" >"$TMP_BODY"
  return 0
}

# ---------- gate 3: humanizer lint ----------

humanizer_lint() { # BODY_FILE → report on stdout; rc 1 when HARD findings exist
  python3 -c "$(cat <<'PYLINT'
import re, sys

src = open(sys.argv[1], encoding="utf-8").read()
src = re.sub(r"<!--.*?-->", "", src, flags=re.S)  # authoring comments are stripped
src = re.sub(r"^[ \t]*(?:```+|~~~+).*?^[ \t]*(?:```+|~~~+)[ \t]*$", "", src, flags=re.S | re.M)
src = re.sub(r"`[^`\n]+`", " ", src)
words = len(re.findall(r"\S+", src))

hard, soft = [], []

em = src.count("\u2014")
rate = (em * 100.0 / words) if words else 0.0
if rate > 2.0:
    hard.append(f"em dash density {rate:.1f}/100 words ({em} dashes in {words} words; limit is 2 per 100 words)")

if re.search(r"not just\s+[^.;!?\n]{1,80}?\s+but\b", src, re.I):
    hard.append('"not just X but Y" construction found')

promo = []
for w in ("seamless", "seamlessly", "robust", "robustness", "cutting-edge"):
    pattern = r"\b" + w.replace("-", r"[- ]") + r"\b"
    if re.search(pattern, src, re.I):
        promo.append(w)
for m in re.finditer(r"\bleverag(?:e|es|ed|ing)\b", src, re.I):
    pre = src[max(0, m.start() - 40):m.start()].lower()
    if not re.search(r"\b(the|a|an|our|their|its|his|her|my|your|this|that|these|those|some|any|more|less|most|little|no|of)\s+(?:\w+\s+){0,1}$", pre):
        promo.append(m.group(0))
if promo:
    hard.append("promotional wording: " + ", ".join(sorted(set(promo))))

triples = len(re.findall(r"[^\n.!?,]{1,60},[ \t]*[^\n.!?,]{1,60},?[ \t]+(?:and|or)[ \t]+", src))
if triples > 3:
    soft.append(f"rule-of-three style: {triples} 'X, Y and Z' triples found (>3 per page)")

passive = len(re.findall(r"\b(?:is|are|was|were|be|been|being|am)\s+\w+(?:ed|en)\b", src, re.I))
if passive > 5:
    soft.append(f"passive voice: {passive} candidate constructions found (>5 per page)")

print(f"humanizer lint: {words} words analysed (HTML comments, fenced blocks and inline code excluded)")
for h in hard:
    print("  HARD: " + h)
for s in soft:
    print("  SOFT: " + s)
if not hard and not soft:
    print("  clean")
sys.exit(1 if hard else 0)
PYLINT
)" "$1"
}

# ---------- conversion ----------

run_converter() { # SRC_MD_FILE DST_XHTML_FILE
  bash "$LIB/convert.sh" "$1" >"$2"
}

# ---------- plan / write ----------

plan_update() {
  if [[ -n "${CONFLUENCE_TOKEN:-}" ]]; then
    local body status ver
    if ! body="$(api_curl GET "/rest/api/content/$FM_ID?expand=version")"; then
      die "$EX_API" "network error fetching current version of page $FM_ID"
    fi
    status="$(cat "$API_STATUS_FILE" 2>/dev/null || printf 000)"
    if [[ "$status" == "200" ]]; then
      ver="$(json_field "$body" version.number)"
      [[ -n "$ver" ]] || die "$EX_API" "could not parse version of page $FM_ID"
      echo "PLAN: UPDATE '$FM_TITLE' v$ver → v$((ver + 1)) (confluence-id $FM_ID)"
      mappings_update page "$REL_PATH" "{\"pending_version\": $ver}" \
        || die "$EX_API" "failed to record dry-run version in mappings.json"
    else
      echo "PLAN: UPDATE '$FM_TITLE' (confluence-id $FM_ID) — version fetch returned HTTP $status; version check deferred to --publish"
    fi
  else
    echo "PLAN: UPDATE '$FM_TITLE' (confluence-id $FM_ID) — CONFLUENCE_TOKEN unset; version check deferred to --publish"
  fi
}

do_create() { # XHTML_FILE REL_PATH
  local xhtml="$1" rel="$2" payload status body new_id
  payload="$(mktemp)"
  add_tmp "$payload"
  api_build_create_payload "$FM_TITLE" "$FM_PARENT" "$(mappings_field space)" "$xhtml" "$payload"
  if ! body="$(api_curl POST "/rest/api/content" "$payload")"; then
    die "$EX_API" "network error during page creation"
  fi
  status="$(cat "$API_STATUS_FILE" 2>/dev/null || printf 000)"
  if [[ "$status" != "200" && "$status" != "201" ]]; then
    echo "CREATE failed: HTTP $status" >&2
    echo "${body:0:600}" >&2
    if [[ "$status" == "400" ]]; then
      die "$EX_API" "Confluence rejected creation — check that parent $FM_PARENT accepts children (folder/page id is valid)"
    fi
    die "$EX_API" "page creation rejected (HTTP $status)"
  fi
  new_id="$(json_field "$body" id)"
  [[ -n "$new_id" ]] || die "$EX_API" "page created but id missing from response"
  mappings_update page "$rel" "{\"confluence-id\": \"$new_id\", \"title\": $(json_quote "$FM_TITLE"), \"last_published_version\": 1, \"pending_version\": null}" \
    || die "$EX_API" "failed to record page in mappings.json"
  echo "PUBLISHED: created page '$FM_TITLE' (id $new_id) under $FM_PARENT"
  echo "NEXT: add 'confluence-id: $new_id' to the frontmatter of $rel so future runs UPDATE this page."
}

do_update() { # XHTML_FILE REL_PATH
  local xhtml="$1" rel="$2" payload status body ver ver2 pending newver
  if ! body="$(api_curl GET "/rest/api/content/$FM_ID?expand=version")"; then
    die "$EX_API" "network error fetching page $FM_ID"
  fi
  status="$(cat "$API_STATUS_FILE" 2>/dev/null || printf 000)"
  if [[ "$status" == "404" ]]; then
    die "$EX_API" "page $FM_ID not found — the confluence-id in $rel may be stale; verify it or clear the field"
  fi
  [[ "$status" == "200" ]] || die "$EX_API" "cannot load page $FM_ID for update: HTTP $status"
  ver="$(json_field "$body" version.number)"
  [[ -n "$ver" ]] || die "$EX_API" "cannot parse current version of page $FM_ID"

  # Update safety: abort if the remote version changed since the dry-run.
  pending="$(page_field "$rel" pending_version)"
  if [[ -n "$pending" && "$pending" != "$ver" ]]; then
    die "$EX_CONFLICT" "remote version changed since your dry-run (dry-run saw v$pending, remote is now v$ver). Re-run './publish.sh $rel' to review the current page, then --publish again."
  fi

  payload="$(mktemp)"
  add_tmp "$payload"
  api_build_update_payload "$FM_ID" "$FM_TITLE" "$((ver + 1))" "$xhtml" "$payload"

  # Race-window check: re-read the version immediately before the PUT.
  if ! body="$(api_curl GET "/rest/api/content/$FM_ID?expand=version")"; then
    die "$EX_API" "network error re-checking version of page $FM_ID"
  fi
  [[ "$(cat "$API_STATUS_FILE" 2>/dev/null || printf 000)" == "200" ]] || die "$EX_API" "version re-check failed: HTTP $(cat "$API_STATUS_FILE" 2>/dev/null || printf 000)"
  ver2="$(json_field "$body" version.number)"
  [[ "$ver2" == "$ver" ]] || die "$EX_CONFLICT" "page changed mid-publish (v$ver → v$ver2). Nothing was written. Re-run dry-run + --publish."

  if ! body="$(api_curl PUT "/rest/api/content/$FM_ID" "$payload")"; then
    die "$EX_API" "network error during page update"
  fi
  status="$(cat "$API_STATUS_FILE" 2>/dev/null || printf 000)"
  if [[ "$status" == "409" ]]; then
    die "$EX_CONFLICT" "version conflict (HTTP 409) on page $FM_ID — it was modified concurrently. Re-run dry-run to fetch the latest version, review, then --publish."
  fi
  if [[ "$status" != "200" ]]; then
    echo "UPDATE failed: HTTP $status" >&2
    echo "${body:0:600}" >&2
    die "$EX_API" "page update rejected"
  fi
  newver="$(json_field "$body" version.number)"
  [[ -n "$newver" ]] || newver="$((ver + 1))"
  mappings_update page "$rel" "{\"last_published_version\": $newver, \"pending_version\": null}" \
    || die "$EX_API" "failed to record published version in mappings.json"
  echo "PUBLISHED: updated page '$FM_TITLE' (id $FM_ID) to v$newver"
}

# ---------- commands ----------

cmd_publish() {
  local file="$1"
  shift
  local do_publish="false" a
  for a in "$@"; do
    case "$a" in
      --publish) do_publish="true" ;;
      *) usage; exit "$EX_USAGE" ;;
    esac
  done

  deps_check
  [[ -f "$file" ]] || die "$EX_USAGE" "file not found: $file"
  [[ "$file" == *.md || "$file" == *.markdown ]] || die "$EX_USAGE" "only markdown files (.md) are published: $file"

  local abs rel mode parent_title lint_rc xhtml total
  abs="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
  rel="${abs#"$ROOT"/}"
  REL_PATH="$rel"
  mode="dry"
  [[ "$do_publish" == "true" ]] && mode="live"

  # Gate 1: frontmatter
  parse_frontmatter "$file" || exit "$EX_FRONTMATTER"
  echo "frontmatter: title='$FM_TITLE' parent=$FM_PARENT confluence-id=${FM_ID:-<none> (CREATE)}"

  # Gate 2: scope guard
  verify_scope "$FM_PARENT" "$mode"

  # Gate 3: humanizer lint (HARD blocks --publish; SOFT warns only)
  lint_rc=0
  humanizer_lint "$TMP_BODY" || lint_rc=$?
  if ((lint_rc != 0)); then
    if [[ "$do_publish" == "true" ]]; then
      die "$EX_LINT" "HARD humanizer findings block --publish (fix the flagged text, then re-run)"
    fi
    echo "dry-run: HARD lint findings above would block --publish" >&2
  fi

  # Convert markdown → storage XHTML
  xhtml="$(mktemp)"
  add_tmp "$xhtml"
  run_converter "$TMP_BODY" "$xhtml" || die "$EX_API" "markdown conversion failed"
  [[ -s "$xhtml" ]] || die "$EX_FRONTMATTER" "document has no publishable content"

  # Plan
  parent_title="$(lookup_parent_title "$FM_PARENT")"
  [[ -n "$parent_title" ]] || parent_title="id $FM_PARENT"
  if [[ -z "$FM_ID" ]]; then
    echo "PLAN: CREATE page '$FM_TITLE' under $parent_title ($FM_PARENT)"
  else
    plan_update
  fi

  # Storage-format preview
  echo "----- storage-format preview (first 50 lines) -----"
  head -n 50 "$xhtml"
  total="$(wc -l <"$xhtml")"
  if ((total > 50)); then
    echo "... ($((total - 50)) more lines)"
  fi
  echo "----------------------------------------------------"

  if [[ "$do_publish" != "true" ]]; then
    echo "DRY-RUN complete — no writes performed. Re-run with --publish to publish."
    return 0
  fi

  api_require_token || exit "$EX_DEPS"
  if [[ -z "$FM_ID" ]]; then
    do_create "$xhtml" "$rel"
  else
    do_update "$xhtml" "$rel"
  fi
}

cmd_init() {
  deps_check
  api_require_token || exit "$EX_DEPS"
  local root
  root="$(mappings_field root_folder_id)"
  [[ -n "$root" ]] || die "$EX_API" "mappings.json is missing root_folder_id"
  echo "Fetching Confluence folder tree under root $root ..."
  python3 -c "$(cat <<'PYWALK'
import base64, datetime, json, os, sys, tempfile, urllib.error, urllib.request

BASE = os.environ.get("CONFLUENCE_BASE_URL", "https://infinitium.atlassian.net/wiki")
EMAIL = os.environ.get("CONFLUENCE_EMAIL", "rizki.rachman@infinitium.com")
TOKEN = os.environ["CONFLUENCE_TOKEN"]
AUTH = base64.b64encode(f"{EMAIL}:{TOKEN}".encode()).decode()
ROOT_ID, MAPPINGS = sys.argv[1], sys.argv[2]
MAX_DEPTH, MAX_ITEMS = 6, 1000


def get(path):
    req = urllib.request.Request(
        BASE + path,
        headers={"Authorization": "Basic " + AUTH, "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def paged(pid, kind):
    out, start = [], 0
    while True:
        d = get(f"/rest/api/content/{pid}/child/{kind}?limit=50&start={start}")
        batch = d.get("results", [])
        out.extend(batch)
        if len(batch) < 50 or len(out) > MAX_ITEMS or start > 2000:
            break
        start += 50
    return out


def short(t):
    return (t[:60] + "...") if len(t) > 60 else t


try:
    root = get(f"/rest/api/content/{ROOT_ID}")
except urllib.error.HTTPError as e:
    sys.stderr.write(f"init: HTTP {e.code} fetching root folder {ROOT_ID}\n")
    raise SystemExit(7)

data = json.load(open(MAPPINGS, encoding="utf-8"))
kf = data.setdefault("known_folders", {})
dp = data.setdefault("discovered_pages", {})
sc = data.setdefault("scope_cache", {})
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
root_title = root.get("title", "")
kf[ROOT_ID] = {"title": root_title, "type": root.get("type", "folder"), "parent_id": None}
sc[ROOT_ID] = {"in_scope": True, "ancestors": [], "title": root_title, "verified_at": now}

lines = [f"{root_title} ({ROOT_ID})  [root folder]"]


def render(pid, depth, prefix, path_ids):
    if depth > MAX_DEPTH:
        lines.append(prefix + "...")
        return
    entries = [(n, "folder") for n in paged(pid, "folder")] + [(n, "page") for n in paged(pid, "page")]
    for idx, (node, kind) in enumerate(entries):
        last = idx == len(entries) - 1
        nid, ntitle = str(node.get("id")), node.get("title", "")
        connector = "└── " if last else "├── "
        lines.append(f"{prefix}{connector}{short(ntitle)} ({nid})  [{kind}]")
        if kind == "folder":
            kf[nid] = {"title": ntitle, "type": "folder", "parent_id": pid}
            sc[nid] = {"in_scope": True, "ancestors": list(path_ids), "title": ntitle, "verified_at": now}
            render(nid, depth + 1, prefix + ("    " if last else "│   "), path_ids + [nid])
        else:
            dp[nid] = {"title": ntitle, "parent_id": pid}


try:
    render(ROOT_ID, 1, "", [])
except urllib.error.HTTPError as e:
    sys.stderr.write(f"init: HTTP {e.code} while walking the folder tree\n")
    raise SystemExit(7)

print("\n".join(lines))
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(MAPPINGS) or ".")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, MAPPINGS)
print(f"init: cached {len(kf)} folders and {len(dp)} pages into mappings.json (scope ancestry verified)", file=sys.stderr)
PYWALK
)" "$root" "$MAPPINGS_FILE" || die "$EX_API" "init failed while fetching the folder tree"
  echo "Pick a parent id from the tree above, then set 'parent: <id>' in your page frontmatter."
}

main() {
  [[ $# -ge 1 ]] || { usage; exit "$EX_USAGE"; }
  case "$1" in
    init)
      shift
      cmd_init "$@"
      ;;
    -h|--help|help)
      usage
      ;;
    --publish|-*)
      usage
      exit "$EX_USAGE"
      ;;
    *)
      cmd_publish "$@"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -e
  trap cleanup EXIT
  main "$@"
fi
