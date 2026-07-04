-- A canned MCP server simulating a DATABASE INTROSPECTOR (the Postgres
-- pattern): tables become graph entities, each stamped with a definition
-- fingerprint, so cartograph can cache the scan and re-introspect only
-- what changed. Run with: luajit pgserver.lua <dbfile>
--
-- dbfile format, one table per line:  <name> <version> <col,col,...>
-- Tool calls are appended to <dbfile>.log so tests can PROVE what was
-- and wasn't rescanned.

local dbfile = arg and arg[1]
assert(dbfile, 'pgserver: no db file')

local function read_db()
    local tables = {}
    local fd = io.open(dbfile, 'r')
    if fd then
        for line in fd:lines() do
            local name, ver, cols = line:match('^(%S+)%s+(%S+)%s+(%S+)$')
            if name then
                tables[#tables + 1] = { name = name, ver = ver, cols = cols }
            end
        end
        fd:close()
    end
    return tables
end

local function log(what)
    local fd = io.open(dbfile .. '.log', 'a')
    if fd then
        fd:write(what .. '\n')
        fd:close()
    end
end

local function graph_json(only)
    local nodes, stamps = {}, {}
    for _, t in ipairs(read_db()) do
        local file = 'tables/' .. t.name
        if not only or only[file] then
            nodes[#nodes + 1] = ('{"id":"%s","name":"%s","kind":"module",'
                .. '"file":"%s","order":-1,"range":{"start":{"line":0,"char":0},'
                .. '"end":{"line":0,"char":0}}}'):format(file, file, file)
            local cols = {}
            for c in t.cols:gmatch('[^,]+') do
                cols[#cols + 1] = ('{"k":"lit","v":"%s"}'):format(c)
            end
            nodes[#nodes + 1] = ('{"id":"%s::table:%s@0","name":"%s",'
                .. '"kind":"var","file":"%s","order":0,'
                .. '"range":{"start":{"line":0,"char":0},"end":{"line":0,"char":0}},'
                .. '"data":[%s]}'):format(file, t.name, t.name, file,
                    table.concat(cols, ','))
            stamps[#stamps + 1] = ('"%s":"%s"'):format(file, t.ver)
        end
    end
    return ('{"schema":1,"nodes":[%s],"edges":[],"calls":[],"stamps":{%s}}')
        :format(table.concat(nodes, ','), table.concat(stamps, ','))
end

local function stamps_json()
    local out = {}
    for _, t in ipairs(read_db()) do
        out[#out + 1] = ('"tables/%s":"%s"'):format(t.name, t.ver)
    end
    return '{' .. table.concat(out, ',') .. '}'
end

local function reply(id, result_json)
    io.write(('{"jsonrpc":"2.0","id":%d,"result":%s}\n'):format(id, result_json))
    io.flush()
end

local function text_result(payload)
    return ('{"content":[{"type":"text","text":"%s"}]}')
        :format(payload:gsub('\\', '\\\\'):gsub('"', '\\"'))
end

for line in io.lines() do
    local id = tonumber(line:match('"id"%s*:%s*(%d+)'))
    if line:find('"initialize"') and id then
        reply(id, [[{"protocolVersion":"2024-11-05","capabilities":{},]]
            .. [["serverInfo":{"name":"pg-fixture","version":"0"}}]])
    elseif line:find('"tools/call"') and id then
        if line:find('"stamps"') then
            log('stamps')
            reply(id, text_result(stamps_json()))
        elseif line:find('"graph"') then
            local only, n = nil, 0
            local list = line:match('"only"%s*:%s*%[(.-)%]')
            if list then
                only = {}
                for k in list:gmatch('"([^"]+)"') do
                    only[k] = true
                    n = n + 1
                end
            end
            log(only and ('graph:only=' .. n) or 'graph')
            reply(id, text_result(graph_json(only)))
        else
            reply(id, [[{"content":[{"type":"text","text":"no such tool"}],"isError":true}]])
        end
    elseif id then
        reply(id, '{}')
    end
end
