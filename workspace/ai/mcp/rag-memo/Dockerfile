# rag-memo-mcp: lightweight, zero-dependency Node.js MCP server for
# hybrid RAG (SQLite FTS5 + vectors) and write-gated agent memory (Memo).
FROM node:22-bookworm-slim

ENV NODE_ENV=production \
    RAG_DB=/data/rag-memo.db \
    MEMO_ENABLED=true \
    MCP_TRANSPORT=stdio

WORKDIR /app
RUN mkdir -p /data && chown node:node /data

# Note: Mount or copy the server implementation at /app/server.js when building
# (for example, from workspace/agents/opencode/rag/server.js).
USER node
VOLUME ["/data"]

ENTRYPOINT ["node", "/app/server.js"]
