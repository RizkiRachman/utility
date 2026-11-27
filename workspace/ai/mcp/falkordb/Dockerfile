# kg-mcpserver: local build of the FalkorDB MCP server with sane defaults baked.
# The upstream image pins MCP_TRANSPORT=http; this build pins a version and
# defaults to stdio (what config/opencode.json needs). Override the env in
# compose to flip transports for debugging.
FROM falkordb/mcpserver:1.3.0
ENV MCP_TRANSPORT=stdio
