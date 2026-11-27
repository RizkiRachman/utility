#!/usr/bin/env bash
# kg-down.sh - stop and remove the FalkorDB containers and network.
# The data directory (KG_DATA_DIR, default /home/node/workspace/kg-data) is kept.
set -euo pipefail
docker rm -f "${KG_DB_NAME:-kg-falkordb}" >/dev/null 2>&1 || true
docker network rm "${KG_NET_NAME:-kg-net}" >/dev/null 2>&1 || true
echo "kg: removed (data kept in ${KG_DATA_DIR:-/home/node/workspace/kg-data})"
