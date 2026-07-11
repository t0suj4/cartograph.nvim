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

test('atlas fields: a multi-writer var decomposes per field', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat({
        'local state = {}',
        'local function setx(v) state.x = v end',       -- x: single-writer
        'local function bump1() state.y = 1 end',       -- y: two writers
        'local function bump2() state.y = 2 end',
        'local function readz() return state.z end',    -- z: read-only
        'local function init() if not state.m then state.m = {} end end',
        'local function dump() return state.x, state.y end',
        'return { setx, bump1, bump2, readz, init, dump }',
    }, '\n'))
    fd:close()
    store.ingest(require('cartograph.providers.treesitter').extract(root))
    local vid
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'var' and n.name == 'state' then vid = n.id end
    end
    ok(vid, 'state var extracted')
    eq('multi-writer', atlas.classify(store, vid).label,
        'edge-level: the aggregate blurs the fields')
    local fa = atlas.fields(store, vid)
    ok(fa, 'field decomposition ran')
    eq('single-writer', fa.fields.x.label, 'x has one owner')
    eq('multi-writer', fa.fields.y.label, 'y is genuinely contended')
    eq('const', fa.fields.z.label, 'z is read-only')
    eq('set-once', fa.fields.m.label, 'm is absence-guarded init')
    eq(nil, fa.fields.x.hedged, 'no whole-var write: claims unhedged')
    eq(0, fa.whole.nw, 'no whole-var writes in this fixture')
end)

test('atlas fields: a whole-var write hedges every field claim', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat({
        'local cfg = {}',
        'local function seta(v) cfg.a = v end',
        'local function reset() cfg = {} end', -- rebind: whole-var write
        'local function get() return cfg.a end',
        'return { seta, reset, get }',
    }, '\n'))
    fd:close()
    store.ingest(require('cartograph.providers.treesitter').extract(root))
    local vid
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'var' and n.name == 'cfg' then vid = n.id end
    end
    local fa = atlas.fields(store, vid)
    ok(fa.whole.nw > 0, 'the rebind lands in the whole bucket as a write')
    ok(fa.fields.a.hedged, '...and hedges the per-field claim')
end)
