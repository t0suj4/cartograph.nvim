-- Golden test for local-function call edges. Idiomatic single-file Lua wires
-- helpers with `local function`, called via getlocal; the extractor must resolve
-- those (guarded to function-valued locals) or a whole module reads as edgeless.
-- Self-skips if the graph CLI isn't installed.

local store = require 'cartograph.store'

local BIN = vim.fn.expand '~/.local/lib/lua-language-server/bin/lua-language-server'
local CLI = vim.fn.expand '~/.local/lib/lua-language-server/script/cli/graph.lua'
local function q(s) return "'" .. s .. "'" end

test('extractor: calls to `local function` helpers become ref edges', function ()
    if vim.fn.executable(BIN) == 0 or vim.fn.filereadable(CLI) == 0 then
        skip 'graph CLI not installed'
    end
    local dir = vim.fn.getcwd() .. '/tests/fixtures/localcalls'
    local out = vim.fn.tempname()
    os.execute(table.concat({
        q(BIN), '--graph=' .. q(dir), '--graphout=' .. q(out),
        '--logpath=' .. q(out .. 'log'), '>/dev/null 2>&1',
    }, ' '))
    store.load(out .. '.json')

    -- id -> name for the function nodes, and a set of (fromName -> toName) refs
    local name = {}
    for _, n in ipairs(store.data.nodes) do name[n.id] = n.name end
    local refs = {}
    for _, e in ipairs(store.data.edges) do
        if e.kind == 'ref' then refs[(name[e.from] or '?') .. '->' .. (name[e.to] or '?')] = true end
    end

    ok(refs['middle->helper'], 'middle -> helper (local call) resolved')
    ok(refs['caller->middle'], 'caller -> middle resolved')
    ok(refs['caller->helper'], 'caller -> helper resolved')

    -- guard check: a non-function local (the returned table field) must NOT
    -- manufacture spurious function edges. Only the three real calls exist.
    local n = 0
    for _ in pairs(refs) do n = n + 1 end
    eq(3, n)
end)
