#!/usr/bin/env bash
# T-task: contract template validates at threshold (fixed eval task, R2-15).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
exec bash "${ENGINE_DIR}/scripts/validate-contract.sh" --file "${ENGINE_DIR}/contract/contract.template.json" --score
