#!/usr/bin/env bash
# merge-shards.sh — crash-safe reconciliation of file-disjoint parallel shards.
# A manifest lists each shard's directory and the relative files it owns.
# Conflicting or unsafe paths abort before any target file is touched. Files
# are staged, then applied by atomic rename under a persistent journal so an
# interruption can be rolled back — immediately by an EXIT/INT/TERM trap, or
# later by an explicit `--recover` after SIGKILL.
set -uo pipefail
MANIFEST=""; TARGET=""; REPORT=""; DRY_RUN=false; RECOVER=false; RUN_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest) MANIFEST="$2"; shift 2 ;; --target) TARGET="$2"; shift 2 ;;
    --report) REPORT="$2"; shift 2 ;; --dry-run) DRY_RUN=true; shift ;;
    --recover) RECOVER=true; shift ;; --run-id) RUN_ID="$2"; shift 2 ;;
    *) echo "merge-shards.sh: unknown arg $1" >&2; exit 2 ;;
  esac
done
[[ -n "$TARGET" ]] || { echo "usage: merge-shards.sh --manifest FILE --target DIR [--report FILE --dry-run | --recover [--run-id ID]]" >&2; exit 2; }
[[ -d "$TARGET" ]] || { echo "merge-shards: target not found: $TARGET" >&2; exit 2; }
[[ "$RECOVER" == true ]] && MANIFEST=""

emit() {
  local json="$1"
  [[ -n "$REPORT" ]] && printf '%s\n' "$json" > "$REPORT" || true
  printf '%s\n' "$json"
}

# Restore every applied file recorded in a state dir's journal. A file with a
# backup is moved back; a previously absent file is removed. Idempotent.
restore_state() {
  local sd="$1" file backup
  [[ -f "$sd/journal.jsonl" ]] || return 0
  while IFS=$'\t' read -r file backup; do
    [[ -n "$file" ]] || continue
    if [[ -n "$backup" && -f "$sd/$backup" ]]; then
      mkdir -p "$TARGET/$(dirname "$file")" 2>/dev/null || true
      mv "$sd/$backup" "$TARGET/$file" 2>/dev/null || true
    else
      rm -f "$TARGET/$file" 2>/dev/null || true
    fi
  done < <(jq -r -s '
      (map(select(.event=="plan")) | map({key:.file, value:(.backup // "")}) | from_entries) as $p
      | map(select(.event=="applied")) | .[]
      | [.file, ($p[.file] // "")] | @tsv
    ' "$sd/journal.jsonl" 2>/dev/null)
}

if [[ "$RECOVER" == true ]]; then
  base="$TARGET/.merge-state"
  [[ -d "$base" ]] || { emit '{"status":"no_state","recovered":0}'; exit 0; }
  recovered=0; failed=0
  for sd in "$base"/*; do
    [[ -d "$sd" ]] || continue
    [[ -n "$RUN_ID" && "$(basename "$sd")" != "$RUN_ID" ]] && continue
    restore_state "$sd" || failed=$((failed+1))
    # A journal without a done marker means it was interrupted; restore.
    rm -rf "$sd" 2>/dev/null || failed=$((failed+1))
    recovered=$((recovered+1))
  done
  rmdir "$base" 2>/dev/null || true
  emit "$(jq -cn --argjson r "$recovered" --argjson f "$failed" '{status:"recovered",recovered:$r,failed:$f}')"
  [[ "$failed" -eq 0 ]]
  exit $?
fi

[[ -f "$MANIFEST" ]] || { echo "merge-shards: manifest not found: $MANIFEST" >&2; exit 2; }
jq -e 'type == "array"' "$MANIFEST" >/dev/null 2>&1 || { echo "merge-shards: manifest must be a JSON array" >&2; exit 2; }

rows=$(jq -r '.[] | [(.name // ""), (.dir // ""), ((.files // [])[])] | @tsv' "$MANIFEST" 2>/dev/null) || { echo "merge-shards: malformed manifest" >&2; exit 2; }
conflicts=$(jq -r '[.[] as $s | ($s.files // [])[] | {file: ., shard: ($s.name // "")}] | group_by(.file) | map(select(length > 1) | {file: .[0].file, shards: (map(.shard) | sort)})' "$MANIFEST" 2>/dev/null)
conflict_count=$(printf '%s\n' "$conflicts" | jq 'length' 2>/dev/null || echo 0)

if [[ "$conflict_count" -ne 0 ]]; then
  emit "$(jq -cn --argjson c "$conflicts" '{status:"conflict",applied:0,conflicts:$c,files:[]}' 2>/dev/null)"
  echo "merge-shards: $conflict_count conflicting file(s); nothing applied" >&2
  exit 1
fi

# Validate and stage every source file before touching any target.
stage=$(mktemp -d) || exit 1
trap 'rm -rf "$stage"' EXIT
while IFS=$'\t' read -r name dir file; do
  [[ -n "$file" ]] || continue
  [[ -n "$name" && -n "$dir" ]] || { echo "merge-shards: shard with missing name/dir" >&2; emit '{"status":"invalid","reason":"missing name or dir"}'; exit 1; }
  [[ -d "$dir" ]] || { echo "merge-shards: shard dir missing: $dir" >&2; emit '{"status":"invalid","reason":"shard dir missing"}'; exit 1; }
  case "$file" in
    /*|*..*|*//*) echo "merge-shards: unsafe path: $file" >&2; emit '{"status":"invalid","reason":"unsafe path"}'; exit 1 ;;
  esac
  [[ -f "$dir/$file" ]] || { echo "merge-shards: source missing: $dir/$file" >&2; emit '{"status":"invalid","reason":"source missing"}'; exit 1; }
  mkdir -p "$stage/files/$(dirname "$file")" || exit 1
  cp "$dir/$file" "$stage/files/$file" 2>/dev/null || exit 1
done <<< "$rows"

if [[ "$DRY_RUN" == true ]]; then
  emit "$(printf '%s\n' "$rows" | jq -R -s 'split("\n") | map(select(length>0)) | map(split("\t")[2]) | {status:"dry_run",applied:0,conflicts:[],files:.}' 2>/dev/null)"
  exit 0
fi

# Persistent state dir: staged files, originals, and a journal. Survives the
# process so --recover can finish rollback after an abrupt termination.
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM}"
base="$TARGET/.merge-state"; sd="$base/$RUN_ID"
mkdir -p "$sd/files" "$sd/backup" || exit 1
cp -R "$stage/files/." "$sd/files/" || exit 1
journal="$sd/journal.jsonl"; : > "$journal"

CLEAN=false
on_exit() {
  local rc=$?
  if [[ "$CLEAN" != true && -d "$sd" ]]; then
    restore_state "$sd" 2>/dev/null || true
    rm -rf "$sd" 2>/dev/null || true
    rmdir "$base" 2>/dev/null || true
  fi
  return "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Write the full plan first: each target's original backup path (or null).
while IFS=$'\t' read -r name dir file; do
  [[ -n "$file" ]] || continue
  backup=""
  if [[ -f "$TARGET/$file" ]]; then
    mkdir -p "$sd/backup/$(dirname "$file")" || exit 1
    cp "$TARGET/$file" "$sd/backup/$file" 2>/dev/null || exit 1
    backup="backup/$file"
  fi
  jq -cn --arg f "$file" --arg b "$backup" '{event:"plan",file:$f,backup:(if $b=="" then null else $b end)}' >> "$journal" || exit 1
done <<< "$rows"

applied=0
declare -a APPLIED_FILES=()
while IFS=$'\t' read -r name dir file; do
  [[ -n "$file" ]] || continue
  mkdir -p "$TARGET/$(dirname "$file")" || exit 1
  mv "$sd/files/$file" "$TARGET/$file" 2>/dev/null || exit 1
  jq -cn --arg f "$file" '{event:"applied",file:$f}' >> "$journal" || exit 1
  APPLIED_FILES+=("$file"); applied=$((applied+1))
  # Deterministic interruption hook: after N applies, drop the traps and exit
  # 137, leaving the state dir and journal exactly as a SIGKILL would.
  if [[ -n "${MERGE_SHARDS_KILL_AFTER:-}" && "$applied" -eq "$MERGE_SHARDS_KILL_AFTER" ]]; then
    trap - EXIT INT TERM
    exit 137
  fi
done <<< "$rows"

CLEAN=true
rm -rf "$sd" 2>/dev/null || true
rmdir "$base" 2>/dev/null || true
file_list=$(printf '%s\n' "${APPLIED_FILES[@]}" | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null)
emit "$(jq -cn --argjson n "$applied" --argjson f "$file_list" '{status:"applied",applied:$n,conflicts:[],files:$f}' 2>/dev/null)"
