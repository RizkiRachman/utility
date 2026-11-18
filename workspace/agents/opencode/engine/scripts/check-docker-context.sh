#!/usr/bin/env bash
# scripts/check-docker-context.sh - best-effort CI guard: every Dockerfile
# COPY source (lines without --from) must exist under the compose build
# context AND not be excluded by ignore rules. Catches the class where a
# tracked file is invisible to the build (pre-install/* exclusions).
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../../../../.." && pwd)
DOCKERFILE="$REPO/workspace/agents/opencode/Dockerfile"
CTX="$REPO/workspace/agents/opencode"
fail=0; checked=0
while IFS= read -r line; do
  case "$line" in "COPY "*|"COPY --"*) : ;; *) continue ;; esac
  case "$line" in *--from=*) continue ;; esac
  srcs=""; dest=""
  for tok in $line; do
    case "$tok" in COPY|--*) continue ;; esac
    if [ -z "$dest" ] && [ -n "$srcs" ]; then dest=$tok; else srcs="$srcs $tok"; fi
  done
  for src in $srcs; do
    case "$src" in ""|*.deb) continue ;; esac
    checked=$((checked + 1))
    if [ ! -e "$CTX/$src" ]; then
      echo "FAIL: COPY source not in build context: $src" >&2; fail=1
    elif git -C "$REPO" check-ignore -q "workspace/agents/opencode/$src" 2>/dev/null; then
      echo "FAIL: COPY source excluded by ignore rules: $src" >&2; fail=1
    fi
  done
done <"$DOCKERFILE"
echo "docker context check: $checked COPY source(s) verified (best-effort)"
exit $fail
