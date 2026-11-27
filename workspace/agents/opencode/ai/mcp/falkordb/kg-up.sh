#!/usr/bin/env bash
# kg-up.sh - start the FalkorDB knowledge-graph stack.
#
# Pulls the DB + MCP server images once, creates the kg-net docker network, and
# starts the kg-falkordb container with data persisted under KG_DATA_DIR. The
# MCP server itself runs per-session from config/opencode.json (docker run -i);
# nothing here is fetched at boot or session start, so the stack stays
# offline-ready. Idempotent: re-running is a no-op while the DB is healthy.
set -euo pipefail

DB_NAME="${KG_DB_NAME:-kg-falkordb}"
NET="${KG_NET_NAME:-kg-net}"
DATA_DIR="${KG_DATA_DIR:-/home/node/workspace/kg-data}"
HOST_PORT="${KG_HOST_PORT:-4679}"
DB_IMAGE="${KG_DB_IMAGE:-falkordb/falkordb:latest}"

mkdir -p "$DATA_DIR"
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
docker image inspect falkordb/mcpserver:latest >/dev/null 2>&1 || docker pull -q falkordb/mcpserver:latest
docker image inspect "$DB_IMAGE" >/dev/null 2>&1 || docker pull -q "$DB_IMAGE"

if docker ps --format '{{.Names}}' | grep -qx "$DB_NAME"; then
  echo "kg: $DB_NAME already running (host 127.0.0.1:${HOST_PORT}, data ${DATA_DIR})"
  exit 0
fi
docker rm -f "$DB_NAME" >/dev/null 2>&1 || true
docker run -d --name "$DB_NAME" --network "$NET" \
  -p "127.0.0.1:${HOST_PORT}:6379" -v "${DATA_DIR}:/data" "$DB_IMAGE" >/dev/null

for _ in $(seq 1 30); do
  if docker exec "$DB_NAME" redis-cli PING 2>/dev/null | grep -q PONG; then
    echo "kg: falkordb ready on 127.0.0.1:${HOST_PORT} (network ${NET}, data ${DATA_DIR})"
    exit 0
  fi
  sleep 1
done
echo "kg: falkordb did not become ready within 30s" >&2
exit 1
