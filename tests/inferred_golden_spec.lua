-- Golden test for the unique-method-name fallback: when vm can't type a
-- receiver (instance out of a storage table), a call to a method name defined
-- exactly once in the workspace links — marked inferred. Ambiguous names and
-- non-call field reads must NOT link. Self-skips without the CLI.

local store = require 'cartograph.store'

local BIN = vim.fn.expand '~/.local/lib/lua-language-server/bin/lua-language-server'
local CLI = vim.fn.expand '~/.local/lib/lua-language-server/script/cli/graph.lua'
local function q(s) return "'" .. s .. "'" end

test('inferred: unique method name links, ambiguous and reads do not', function ()
    if vim.fn.executable(BIN) == 0 or vim.fn.filereadable(CLI) == 0 then
        skip 'graph CLI not installed'
    end
    local dir = vim.fn.getcwd() .. '/tests/fixtures/inferred'
    local out = vim.fn.tempname()
    os.execute(table.concat({
        q(BIN), '--graph=' .. q(dir), '--graphout=' .. q(out),
        '--logpath=' .. q(out .. 'log'), '>/dev/null 2>&1',
    }, ' '))
    store.load(out .. '.json')

    local ids = {}
    for id, n in pairs(store.by_id) do ids[n.name] = id end
    local fire = assert(ids['M.fire'], 'M.fire node')

    -- unique name: fire -> Thing:zap exists and is flagged inferred
    local has_zap = false
    for _, to in ipairs(store.uses[fire] or {}) do
        if to == ids['Thing:zap'] then has_zap = true end
        ok(to ~= ids['Thing:dup'],  'ambiguous dup must not link to Thing')
        ok(to ~= ids['Other:dup'],  'ambiguous dup must not link to Other')
    end
    ok(has_zap, 'fire -> Thing:zap linked by name')
    ok(store.edge_inferred[fire .. '\31' .. ids['Thing:zap']], 'flagged inferred')

    -- the field READ (local z = t.zap) must not have added an occurrence:
    -- exactly one call site recorded on the edge
    eq(1, #store.occurrences(fire, ids['Thing:zap']))

    -- vm-resolved edge (Thing.get via local) is NOT flagged
    ok(not store.edge_inferred[fire .. '\31' .. ids['Thing.get']], 'vm edge unflagged')

    -- and the swallowed-type lint points at the ROOT CAUSE: the getter
    local lint = require 'cartograph.lint'
    local f = lint.run(store, { only = { ['swallowed-type'] = true } })
    eq(1, #f)
    eq('---@return Thing', f[1].fix.text)
    eq(store.node(ids['Thing.get']).range.start.line + 1, f[1].line)
end)
