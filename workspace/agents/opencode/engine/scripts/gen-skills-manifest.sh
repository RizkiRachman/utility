#!/usr/bin/env bash
# gen-skills-manifest.sh - build engine/skills.json from engine/skills/*/SKILL.md
#
# The manifest is baked into the image at build time so boot checks can
# validate the shipped skill set without scanning the tree at runtime.
#
# Usage: gen-skills-manifest.sh [OUTPUT_PATH]
#   OUTPUT_PATH defaults to <engine-root>/skills.json
#
# Extraction per skill:
#   name        - frontmatter `name:`, else the first `# heading`
#   description - frontmatter `description:` (block scalars flattened),
#                 else the first non-empty paragraph line
# Output is ASCII-only.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ENGINE_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SKILLS_DIR="$ENGINE_DIR/skills"
OUTPUT="${1:-$ENGINE_DIR/skills.json}"

if [ ! -d "$SKILLS_DIR" ]; then
  echo "gen-skills-manifest: skills directory not found: $SKILLS_DIR" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "gen-skills-manifest: jq is required" >&2
  exit 1
fi

WORK_DIR="${TMPDIR:-/tmp/opencode}"
mkdir -p "$WORK_DIR"
TMP_FILE="$WORK_DIR/gen-skills-manifest.$$.jsonl"
: > "$TMP_FILE"
trap 'rm -f "$TMP_FILE"' EXIT INT TERM

sanitize() {
  printf '%s' "$1" \
    | tr '\t' ' ' \
    | sed 's/\xe2\x80\x94/ - /g; s/\xe2\x80\x93/-/g' \
    | tr -cd '\40-\176' \
    | tr -s ' ' \
    | sed 's/^ *//; s/ *$//'
}

extract() {
  awk '
    BEGIN { in_fm = 0; block = 0; name = ""; desc = ""; heading = ""; para = "" }
    NR == 1 && $0 == "---" { in_fm = 1; next }
    in_fm && $0 == "---" { in_fm = 0; next }
    in_fm {
      if (block == 1) {
        if ($0 ~ /^[ \t]+/) {
          line = $0
          sub(/^[ \t]+/, "", line)
          desc = (desc == "" ? line : desc " " line)
          next
        }
        block = 0
      }
      if ($0 ~ /^name:[ \t]*/) {
        line = $0
        sub(/^name:[ \t]*/, "", line)
        if (name == "") name = line
        next
      }
      if ($0 ~ /^description:[ \t]*/) {
        line = $0
        sub(/^description:[ \t]*/, "", line)
        if (line ~ /^[>|]/) {
          block = 1
        } else {
          desc = line
        }
        next
      }
      next
    }
    {
      if (heading == "" && $0 ~ /^# /) {
        line = $0
        sub(/^# /, "", line)
        heading = line
      }
      if (para == "" && $0 !~ /^[ \t]*$/ && $0 !~ /^#/ && $0 !~ /^```/ && $0 !~ /^<!--/) {
        para = $0
      }
    }
    END {
      if (name == "") name = heading
      if (desc == "") desc = para
      gsub(/\t/, " ", name)
      gsub(/\t/, " ", desc)
      print name
      print desc
    }
  ' "$1"
}

count=0
for skill_md in "$SKILLS_DIR"/*/SKILL.md; do
  [ -f "$skill_md" ] || continue
  dir=$(basename "$(dirname "$skill_md")")
  raw_name=""
  raw_desc=""
  {
    IFS= read -r raw_name || true
    IFS= read -r raw_desc || true
  } <<EOF
$(extract "$skill_md")
EOF
  name=$(sanitize "$raw_name")
  desc=$(sanitize "$raw_desc")
  [ -n "$name" ] || name="$dir"
  jq -cn --arg name "$name" --arg description "$desc" \
    --arg path "engine/skills/$dir" \
    '{name: $name, description: $description, path: $path}' >> "$TMP_FILE"
  count=$((count + 1))
done

jq -s --arg version "1.0" --arg gen "gen-skills-manifest.sh" \
  '{version: $version, generated_by: $gen, count: length, skills: .}' \
  "$TMP_FILE" > "$OUTPUT"

echo "gen-skills-manifest: wrote $count skills to $OUTPUT"
