#!/usr/bin/env bash
# detect-architecture-patterns.sh — Detect architecture pattern violations via lean-ctx
# Uses the knowledge graph to find structural issues: god classes, circular deps, missing contracts
# Usage: bash scripts/detect-architecture-patterns.sh [--dir SRC_DIR]
# Example: bash scripts/detect-architecture-patterns.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR=""
VERBOSE=false

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Detect architecture pattern violations using static analysis.

Options:
  --dir PATH        Source directory to analyze (default: src/)
  --verbose         Detailed output
  --help            Show this message
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir) SRC_DIR="$2"; shift 2 ;;
        --verbose) VERBOSE=true; shift ;;
        --help|-h) usage ;;
        *) echo "Unknown: $1"; usage ;;
    esac
done

if [[ -z "$SRC_DIR" ]]; then
    for candidate in src src/main/java src/main/kotlin app; do
        if [[ -d "$PROJECT_DIR/$candidate" ]]; then
            SRC_DIR="$PROJECT_DIR/$candidate"
            break
        fi
    done
fi
if [[ -z "$SRC_DIR" || ! -d "$SRC_DIR" ]]; then
    SRC_DIR="$PROJECT_DIR"
fi

echo "=========================================="
echo " Architecture Pattern Detection"
echo " Directory: $SRC_DIR"
echo "=========================================="
echo ""

PATTERN_VIOLATIONS=0
CRITICAL=false

# Pattern 1: Detect god classes (classes with too many methods)
log_info "Pattern 1: God class detection..."
if command -v grep &>/dev/null; then
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        # Count methods as lines starting with 'public function', 'def ', 'fun ', etc.
        method_count=$(grep -cE '^\s*(public|private|protected)?\s*(function|def|fun|void|int|String|boolean|Boolean|Object|static).*\(' "$f" 2>/dev/null || true)
        if [[ "$method_count" -gt 20 ]]; then
            rel_path="${f#$PROJECT_DIR/}"
            log_fail "Possible god class: $rel_path ($method_count methods)"
            PATTERN_VIOLATIONS=$((PATTERN_VIOLATIONS + 1))
        fi
    done < <(find "$SRC_DIR" -type f \( -name '*.java' -o -name '*.kt' -o -name '*.ts' -o -name '*.py' \) -not -path '*/test/*' -not -path '*/tests/*' 2>/dev/null || true)
    if [[ "$PATTERN_VIOLATIONS" -eq 0 ]]; then
        log_pass "No god classes detected"
    fi
fi

# Pattern 2: Check for circular module dependencies
log_info "Pattern 2: Circular dependency detection..."
ORIG_PATTERN_VIOLATIONS=$PATTERN_VIOLATIONS

# Look for modules that import from modules they export to
declare -A MODULE_IMPORTS
while IFS= read -r f; do
    module_dir=$(dirname "${f#$SRC_DIR/}" | cut -d/ -f1)
    imports=$(grep -oE 'import.*' "$f" 2>/dev/null | grep -oE '/([a-zA-Z]+)/' | tr -d '/' | sort -u || true)
    while IFS= read -r imp; do
        [[ -z "$imp" ]] && continue
        key="$module_dir:$imp"
        MODULE_IMPORTS["$key"]=$((MODULE_IMPORTS["$key"] + 1))
    done <<< "$imports"
done < <(find "$SRC_DIR" -type f -name '*.java' 2>/dev/null || true)

# If modules A→B and B→A exist, that's a cycle
for key in "${!MODULE_IMPORTS[@]}"; do
    from="${key%%:*}"
    to="${key##*:}"
    reverse="$to:$from"
    if [[ -n "${MODULE_IMPORTS[$reverse]:-}" && "$from" < "$to" ]]; then
        log_fail "Circular dependency: $from ↔ $to (${MODULE_IMPORTS[$key]}+${MODULE_IMPORTS[$reverse]} refs)"
        PATTERN_VIOLATIONS=$((PATTERN_VIOLATIONS + 1))
    fi
done
if [[ "$PATTERN_VIOLATIONS" -eq "$ORIG_PATTERN_VIOLATIONS" ]]; then
    log_pass "No circular dependencies detected"
fi

# Pattern 3: Detect missing hexagonal architecture contracts
log_info "Pattern 3: Hexagonal architecture contract check..."
PORTS_DIR="$SRC_DIR"
SERVICES_DIR="$SRC_DIR"
for p in port port/in port/out ports ports/in ports/out; do
    if [[ -d "$SRC_DIR/$p" ]]; then PORTS_DIR="$SRC_DIR/$p"; break; fi
done
for s in service services domain domain/service; do
    if [[ -d "$SRC_DIR/$s" ]]; then SERVICES_DIR="$SRC_DIR/$s"; break; fi
done

# Check that port interfaces exist for each service implementation
if [[ -d "$PORTS_DIR" && -d "$SERVICES_DIR" ]]; then
    while IFS= read -r svc_file; do
        [[ -z "$svc_file" ]] && continue
        svc_name=$(basename "$svc_file" | sed 's/\.[^.]*$//' | sed 's/Impl$//' | sed 's/Service$//')
        # Check for matching port interface
        port_found=false
        while IFS= read -r port_file; do
            port_base=$(basename "$port_file" | sed 's/\.[^.]*$//')
            if echo "$port_base" | grep -qi "$svc_name"; then
                port_found=true
                break
            fi
        done < <(find "$PORTS_DIR" -type f 2>/dev/null)
        if ! $port_found; then
            rel_path="${svc_file#$PROJECT_DIR/}"
            log_fail "Orphan service: $rel_path has no matching port interface"
            PATTERN_VIOLATIONS=$((PATTERN_VIOLATIONS + 1))
        fi
    done < <(find "$SERVICES_DIR" -type f 2>/dev/null)
    if [[ "$PATTERN_VIOLATIONS" -eq "$ORIG_PATTERN_VIOLATIONS" ]]; then
        log_pass "All services have matching port interfaces"
    fi
else
    log_info "No port/service directories found — skipping hexagonal check"
fi

# Pattern 4: Detect potential null-safety issues
log_info "Pattern 4: Null safety detection..."
ORIG_VIOLATIONS=$PATTERN_VIOLATIONS
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    null_return=$(grep -c 'return null' "$f" 2>/dev/null || true)
    if [[ "${null_return:-0}" -gt 3 ]]; then
        rel_path="${f#$PROJECT_DIR/}"
        log_fail "Null returns in $rel_path: $null_return occurrences (consider using Optional)"
        PATTERN_VIOLATIONS=$((PATTERN_VIOLATIONS + 1))
    fi
done < <(find "$SRC_DIR" -type f \( -name '*.java' -o -name '*.kt' \) -not -path '*/test/*' -not -path '*/tests/*' 2>/dev/null || true)
if [[ "$PATTERN_VIOLATIONS" -eq "$ORIG_VIOLATIONS" ]]; then
    log_pass "No excessive null returns"
fi

echo ""
echo "------------------------------------------"
echo " Pattern violations: $PATTERN_VIOLATIONS"
echo "------------------------------------------"

if [[ "$PATTERN_VIOLATIONS" -eq 0 ]]; then
    echo -e "${GREEN}VERDICT: ALL PATTERNS FOLLOWED${NC}"
    exit 0
else
    echo -e "${YELLOW}VERDICT: $PATTERN_VIOLATIONS pattern violations detected${NC}"
    exit 1
fi
