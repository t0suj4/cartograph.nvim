-- A minimal, protocol-correct MCP stdio server for tests: newline-delimited
-- JSON-RPC 2.0, one tool ('graph') returning a tiny neutral-schema graph.
-- Run with: luajit server.lua

local GRAPH = [[{
  "schema": 1, "root": "/mcp-world", "provider": "mcp-fixture",
  "nodes": [
    {"id": "world::spawn@0", "name": "spawn", "kind": "function",
     "file": "world.rules", "order": 0,
     "range": {"start": {"line": 0, "char": 0}, "end": {"line": 3, "char": 0}}},
    {"id": "world::tick@5", "name": "tick", "kind": "function",
     "file": "world.rules", "order": 5,
     "range": {"start": {"line": 5, "char": 0}, "end": {"line": 9, "char": 0}}}
  ],
  "edges": [
    {"from": "world::tick@5", "to": "world::spawn@0", "kind": "ref",
     "at": [{"start": {"line": 7, "char": 2}, "end": {"line": 7, "char": 7}}]}
  ],
  "calls": []
}]]

local function reply(id, result_json)
    io.write(('{"jsonrpc":"2.0","id":%d,"result":%s}\n'):format(id, result_json))
    io.flush()
end

for line in io.lines() do
    local id = tonumber(line:match('"id"%s*:%s*(%d+)'))
    if line:find('"initialize"') and id then
        reply(id, [[{"protocolVersion":"2024-11-05","capabilities":{},]]
            .. [["serverInfo":{"name":"fixture","version":"0"}}]])
    elseif line:find('"tools/call"') and id then
        if line:find('"graph"') then
            local payload = GRAPH:gsub('\n', ' '):gsub('"', '\\"')
            reply(id, ('{"content":[{"type":"text","text":"%s"}]}'):format(payload))
        else
            reply(id, [[{"content":[{"type":"text","text":"no such tool"}],"isError":true}]])
        end
    elseif id then
        reply(id, '{}')
    end
end
