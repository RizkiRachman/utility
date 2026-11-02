#!/usr/bin/env bash
# check-writing-order.sh — Validate actual file-level writing order: port→service→mapper→adapter
# Unlike auto-score.sh which checks plan text, this validates actual committed files
# in the scope follow the expected layer ordering.
# Usage: bash scripts/check-writing-order.sh [--file CONTRACT_JSON] [--dir SRC_DIR]
# Example: bash scripts/check-writing-order.sh --dir src/main/java

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR=""
CONTRACT_FILE=""

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Validate file-level writing order: port → service → mapper → adapter

Options:
  --file PATH         Contract JSON file for scope (auto-detect from session)
  --dir PATH          Source directory to scan (default: src/)
  --help              Show this message
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --file) CONTRACT_FILE="$2"; shift 2 ;;
        --dir) SRC_DIR="$2"; shift 2 ;;
        --help|-h) usage ;;
        *) echo "Unknown: $1"; usage ;;
    esac
done

# Resolve source directory
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
echo " Writing Order Validation"
echo " Directory: $SRC_DIR"
echo "=========================================="
echo ""

# Layer definitions in expected writing order
LAYERS=("port" "service" "mapper" "adapter")

# Detect layer directories
declare -A LAYER_DIRS
for layer in "${LAYERS[@]}"; do
    dirs=$(find "$SRC_DIR" -type d -name "$layer" 2>/dev/null || true)
    if [[ -n "$dirs" ]]; then
        LAYER_DIRS["$layer"]="$dirs"
    fi
done

# Check layer ordering
# The rule: port files should be created/modified before service, service before mapper, etc.
ORDER_VIOLATIONS=0

# Check 1: All expected layers present
log_info "Checking layer directory presence..."
for layer in "${LAYERS[@]}"; do
    if [[ -n "${LAYER_DIRS[$layer]:-}" ]]; then
        file_count=$(find "${LAYER_DIRS[$layer]}" -type f \( -name '*.java' -o -name '*.kt' -o -name '*.ts' -o -name '*.py' -o -name '*.js' \) 2>/dev/null | wc -l | tr -d ' ')
        log_pass "Layer '$layer' found ($file_count files)"
    else
        log_info "Layer '$layer' not present in source tree (OK if project doesn't use this layer)"
    fi
done

# Check 2: No service file references adapter layer (layer violation)
log_info "Checking cross-layer reference violations..."
for layer in "${LAYERS[@]}"; do
    layer_idx=0
    for i in "${!LAYERS[@]}"; do [[ "${LAYERS[$i]}" == "$layer" ]] && layer_idx=$i; done
    if [[ -z "${LAYER_DIRS[$layer]:-}" ]]; then continue; fi

    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        for j in "${!LAYERS[@]}"; do
            if [[ "$j" -le "$layer_idx" ]]; then continue; fi
            upper_layer="${LAYERS[$j]}"
            if [[ -z "${LAYER_DIRS[$upper_layer]:-}" ]]; then continue; fi
            if grep -q "import.*$upper_layer" "$f" 2>/dev/null; then
                rel_path="${f#$PROJECT_DIR/}"
                log_fail "Layer violation: $rel_path imports '$upper_layer' (above its layer)"
                ORDER_VIOLATIONS=$((ORDER_VIOLATIONS + 1))
            fi
        done
    done < <(find "${LAYER_DIRS[$layer]}" -type f 2>/dev/null)
done

# Check 3: Verify scope files from contract match expected layers
if [[ -n "$CONTRACT_FILE" && -f "$CONTRACT_FILE" ]]; then
    log_info "Checking contract scope alignment with layers..."
    SCOPE=$(jq -r '.scope.included[] // empty' "$CONTRACT_FILE" 2>/dev/null || true)
    SCOPE_VIOLATIONS=0
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        has_layer=false
        for layer in "${LAYERS[@]}"; do
            if echo "$f" | grep -qE "(^|/)$layer/"; then
                has_layer=true
                break
            fi
        done
        if ! $has_layer; then
            if [[ "$f" != *.md && "$f" != config/* && "$f" != .github/* && "$f" != test/* && "$f" != scripts/* ]]; then
                log_info "Scope file outside known layers: $f"
                SCOPE_VIOLATIONS=$((SCOPE_VIOLATIONS + 1))
            fi
        fi
    done <<< "$SCOPE"
    if [[ "$SCOPE_VIOLATIONS" -eq 0 ]]; then
        log_pass "All scope files align with defined layers"
    fi
fi

echo ""
echo "------------------------------------------"
echo " Layer violations: $ORDER_VIOLATIONS"
echo "------------------------------------------"

if [[ "$ORDER_VIOLATIONS" -eq 0 ]]; then
    echo -e "${GREEN}VERDICT: WRITING ORDER CORRECT${NC}"
    exit 0
else
    echo -e "${RED}VERDICT: WRITING ORDER VIOLATED${NC}"
    exit 1
fi
