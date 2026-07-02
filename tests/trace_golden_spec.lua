-- Golden test: run the real --graph CLI on the trace fixture and trace
-- M.set_speed's `speed` parameter end-to-end. Self-skips without the CLI.

local store = require 'cartograph.store'
local trace = require 'cartograph.trace'

local BIN = vim.fn.expand '~/.local/lib/lua-language-server/bin/lua-language-server'
local CLI = vim.fn.expand '~/.local/lib/lua-language-server/script/cli/graph.lua'
local function q(s) return "'" .. s .. "'" end

test('trace: end-to-end on the fixture (extract -> origins -> expand)', function ()
    if vim.fn.executable(BIN) == 0 or vim.fn.filereadable(CLI) == 0 then
        skip 'graph CLI not installed'
    end
    local dir = vim.fn.getcwd() .. '/tests/fixtures/trace'
    local out = vim.fn.tempname()
    os.execute(table.concat({
        q(BIN), '--graph=' .. q(dir), '--graphout=' .. q(out),
        '--logpath=' .. q(out .. 'log'), '>/dev/null 2>&1',
    }, ' '))
    store.load(out .. '.json')

    local speed_fn
    for id, n in pairs(store.by_id) do
        if n.name == 'M.set_speed' then speed_fn = id end
    end
    ok(speed_fn, 'M.set_speed found')
    eq('obj',   store.node(speed_fn).params[1])
    eq('speed', store.node(speed_fn).params[2])

    local origins = trace.origins(store, speed_fn, 2)
    local kinds = {}
    for _, o in ipairs(origins) do kinds[o.v.k] = (kinds[o.v.k] or 0) + 1 end
    eq(1, kinds['local'])  -- s
    eq(2, kinds['param'])  -- x in M.caller, a in obj:go
    eq(1, kinds['lit'])    -- 5
    eq(1, kinds['call'])   -- ident(1)
    eq(1, kinds['field'])  -- t.speed

    -- expand the call origin: ident returns its param, which expands to the
    -- literal 1 at its only call site — a two-hop trace through a function
    for _, o in ipairs(origins) do
        if o.v.k == 'call' then
            local rets = trace.expand(store, o)
            eq('param', rets[1].v.k)
            local up = trace.expand(store, rets[1])
            eq(1, up[1].v.v)
        end
    end
end)
