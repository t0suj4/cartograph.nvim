-- The state atlas: vars classified by their use-edge facts (rw/gw). Pure
-- consumer — synthetic edges drive every label; one real extract proves
-- the end-to-end story.

local atlas = require 'cartograph.atlas'
local store = require 'cartograph.store'

local R = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
local function node(id, kind)
    return { id = id, name = id, kind = kind or 'var',
        file = 'm.lua', range = R, order = 0 }
end
local function use(from, to, rw, gw)
    return { from = from, to = to, kind = 'use', at = { R }, rw = rw, gw = gw }
end

test('atlas: every label from edge facts', function ()
    local fns = {}
    for _, f in ipairs({ 'r1', 'r2', 'w1', 'w2' }) do
        fns[#fns + 1] = node(f, 'function')
    end
    store.ingest({
        root = '/x',
        nodes = { fns[1], fns[2], fns[3], fns[4],
            node('CONST'), node('DEAD'), node('ONCE'),
            node('OWNED'), node('SHARED'), node('MYSTERY') },
        edges = {
            use('r1', 'CONST', 1), use('r2', 'CONST', 1),
            use('w1', 'DEAD', 2), use('w2', 'DEAD', 2),
            use('w1', 'ONCE', 2, 3), use('r1', 'ONCE', 1),
            use('w1', 'OWNED', 3, 1), use('r1', 'OWNED', 1), use('r2', 'OWNED', 1),
            use('w1', 'SHARED', 2, 2), use('w2', 'SHARED', 3, 1), use('r1', 'SHARED', 1),
            use('r1', 'MYSTERY'), use('w1', 'MYSTERY', 2),
        },
        calls = {},
    })
    local got = {}
    for _, v in ipairs({ 'CONST', 'DEAD', 'ONCE', 'OWNED', 'SHARED', 'MYSTERY' }) do
        got[v] = atlas.classify(store, v).label
    end
    eq({ CONST = 'const', DEAD = 'dead', ONCE = 'set-once',
        OWNED = 'single-writer', SHARED = 'multi-writer',
        MYSTERY = 'unclassified' }, got)
    local c = atlas.classify(store, 'OWNED')
    eq(1, c.nw, 'one writer')
    eq('w1', c.writers[1], '...and it is named')
    eq(3, c.nr, 'rw=3 counts as a read too')
    local census = atlas.census(store)
    eq(6, census.total)
    eq(1, census.counts['dead'])
    eq('DEAD', census.vars.dead[1].name)
end)

test('atlas: end-to-end on a real extract', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat({
        'local limit = 10',                -- read only -> const
        'local trace = {}',                -- written, never read -> dead
        -- (note: trace[#trace+1]=x would NOT be dead — the # reads it)
        'local memo = {}',                 -- set-once writes + reads
        'local function f(x)',
        '    if not memo[x] then memo[x] = x * limit end',
        '    trace.last = x',
        '    return memo[x]',
        'end',
        'return { f = f }',
    }, '\n'))
    fd:close()
    store.ingest(require('cartograph.providers.treesitter').extract(root))
    local byname = {}
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'var' then byname[n.name] = atlas.classify(store, n.id).label end
    end
    eq('const', byname.limit)
    eq('dead', byname.trace)
    eq('set-once', byname.memo)
end)
