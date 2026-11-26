#!/usr/bin/env bash
# merge-shards.sh — atomic reconciliation of file-disjoint parallel shards.
# A manifest lists each shard's directory and the relative files it owns.
# Conflicting or unsafe paths abort before any target file is touched; a failed
# copy rolls back every already-applied file.
set -uo pipefail
MANIFEST=""; TARGET=""; REPORT=""; DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest) MANIFEST="$2"; shift 2 ;; --target) TARGET="$2"; shift 2 ;;
    --report) REPORT="$2"; shift 2 ;; --dry-run) DRY_RUN=true; shift ;;
    *) echo "merge-shards.sh: unknown arg $1" >&2; exit 2 ;;
  esac
done
[[ -n "$MANIFEST" && -n "$TARGET" ]] || { echo "usage: merge-shards.sh --manifest FILE --target DIR [--report FILE --dry-run]" >&2; exit 2; }
[[ -f "$MANIFEST" ]] || { echo "merge-shards: manifest not found: $MANIFEST" >&2; exit 2; }
jq -e 'type == "array"' "$MANIFEST" >/dev/null 2>&1 || { echo "merge-shards: manifest must be a JSON array" >&2; exit 2; }
[[ -d "$TARGET" ]] || { echo "merge-shards: target not found: $TARGET" >&2; exit 2; }

rows=$(jq -r '.[] | [(.name // ""), (.dir // ""), ((.files // [])[])] | @tsv' "$MANIFEST" 2>/dev/null) || { echo "merge-shards: malformed manifest" >&2; exit 2; }
conflicts=$(jq -r '[.[] as $s | ($s.files // [])[] | {file: ., shard: ($s.name // "")}] | group_by(.file) | map(select(length > 1) | {file: .[0].file, shards: (map(.shard) | sort)})' "$MANIFEST" 2>/dev/null)
conflict_count=$(printf '%s\n' "$conflicts" | jq 'length' 2>/dev/null || echo 0)

emit() {
  local json="$1"
  [[ -n "$REPORT" ]] && printf '%s\n' "$json" > "$REPORT" || true
  printf '%s\n' "$json"
}
if [[ "$conflict_count" -ne 0 ]]; then
  emit "$(jq -cn --argjson c "$conflicts" '{status:"conflict",applied:0,conflicts:$c,files:[]}' 2>/dev/null)"
  echo "merge-shards: $conflict_count conflicting file(s); nothing applied" >&2
  exit 1
fi

stage=$(mktemp -d) || exit 1
trap 'rm -rf "$stage"' EXIT
applied=0
declare -a APPLIED_FILES=()
rollback() {
  local f
  for f in "${APPLIED_FILES[@]}"; do
    if [[ -f "$stage/backup/$f" ]]; then cp "$stage/backup/$f" "$TARGET/$f" 2>/dev/null
    else rm -f "$TARGET/$f" 2>/dev/null; fi
  done
}

while IFS=$'\t' read -r name dir file; do
  [[ -n "$file" ]] || continue
  [[ -n "$name" && -n "$dir" ]] || { echo "merge-shards: shard with missing name/dir" >&2; rollback; emit '{"status":"invalid","reason":"missing name or dir"}'; exit 1; }
  [[ -d "$dir" ]] || { echo "merge-shards: shard dir missing: $dir" >&2; rollback; emit '{"status":"invalid","reason":"shard dir missing"}'; exit 1; }
  case "$file" in
    /*|*..*|*//*) echo "merge-shards: unsafe path: $file" >&2; rollback; emit '{"status":"invalid","reason":"unsafe path"}'; exit 1 ;;
  esac
  [[ -f "$dir/$file" ]] || { echo "merge-shards: source missing: $dir/$file" >&2; rollback; emit '{"status":"invalid","reason":"source missing"}'; exit 1; }
  mkdir -p "$stage/files/$(dirname "$file")" || { rollback; exit 1; }
  cp "$dir/$file" "$stage/files/$file" 2>/dev/null || { rollback; exit 1; }
done <<< "$rows"

if [[ "$DRY_RUN" == true ]]; then
  emit "$(printf '%s\n' "$rows" | jq -R -s 'split("\n") | map(select(length>0)) | map(split("\t")[2]) | {status:"dry_run",applied:0,conflicts:[],files:.}' 2>/dev/null)"
  exit 0
fi

while IFS=$'\t' read -r name dir file; do
  [[ -n "$file" ]] || continue
  mkdir -p "$TARGET/$(dirname "$file")" || { rollback; emit '{"status":"failed","reason":"mkdir"}'; exit 1; }
  if [[ -f "$TARGET/$file" ]]; then
    mkdir -p "$stage/backup/$(dirname "$file")" || { rollback; exit 1; }
    cp "$TARGET/$file" "$stage/backup/$file" 2>/dev/null || { rollback; exit 1; }
  fi
  cp "$stage/files/$file" "$TARGET/$file" 2>/dev/null || { rollback; emit '{"status":"failed","reason":"copy"}'; exit 1; }
  APPLIED_FILES+=("$file"); applied=$((applied+1))
done <<< "$rows"

file_list=$(printf '%s\n' "${APPLIED_FILES[@]}" | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null)
emit "$(jq -cn --argjson n "$applied" --argjson f "$file_list" '{status:"applied",applied:$n,conflicts:[],files:$f}' 2>/dev/null)"
