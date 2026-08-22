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

-- ── ABSENCE IS NOT EVIDENCE (CART-0478) ─────────────────────────────────────
test('atlas: no use edge at all is UNOBSERVED, never const', function ()
    -- `nw == 0 -> const` was tested before any evidence check, so a var with
    -- nothing read, nothing written and nothing known got the STRONGEST word on
    -- the ladder. Measured: every zero-evidence var was labelled const, 605 of
    -- 605 on mantis, 81% of all vars carrying the label.
    store.ingest({
        root = '/x',
        nodes = { node('SEEN'), node('NOTHING'), node('r1', 'function') },
        edges = { use('r1', 'SEEN', 1) },
        calls = {},
    })
    eq('const', atlas.classify(store, 'SEEN').label,
        'a var that is read and never written is genuinely const')
    eq('unobserved', atlas.classify(store, 'NOTHING').label,
        'a var with no edge at all claims nothing')
    eq(0, atlas.classify(store, 'NOTHING').nr)
end)

test('atlas: UNOBSERVED and UNCLASSIFIED are different facts', function ()
    -- the boundary is NO EDGES vs UNREADABLE EDGES. jquery has 38 vars with
    -- edges whose rw is nil (javascript ships no write classifier) and NONE of
    -- them is unobserved -- a probe that tested `nr == 0 and nw == 0` instead
    -- conflated the two and reported 38 of jquery's 41 vars as unobserved.
    store.ingest({
        root = '/x',
        nodes = { node('NOEDGE'), node('UNREADABLE'), node('r1', 'function') },
        edges = { { from = 'r1', to = 'UNREADABLE', kind = 'use', at = { R } } },
        calls = {},
    })
    eq('unobserved', atlas.classify(store, 'NOEDGE').label)
    eq('unclassified', atlas.classify(store, 'UNREADABLE').label,
        'an edge we cannot read is not an absent edge')
end)

test('atlas: a DERIVED read is evidence, so it lifts unobserved', function ()
    -- and it only counts when asked: the browser and dead-state ask, so what a
    -- reader sees relabelled on mantis is 213 vars rather than 605
    local keyaccess = require 'cartograph.keyaccess'
    store.ingest({ root = '/x', nodes = { node('BYKEY') }, edges = {}, calls = {} })
    eq('unobserved', atlas.classify(store, 'BYKEY').label)
    -- stub the read index for this graph: the derivation itself is pinned in
    -- keyaccess_spec, what matters here is that classify CONSULTS it
    local idx = keyaccess.read_index(store)
    idx['BYKEY'] = { { name = 'BYKEY', acc = 'a', file = 'm.php', line = 1 } }
    eq('const', atlas.classify(store, 'BYKEY', { derived = true }).label,
        'a string-keyed read is a read, so the var is const WITH evidence')
    eq('unobserved', atlas.classify(store, 'BYKEY').label,
        'and the default still does not pay for the index')
end)

test('atlas: unobserved is in the public label set, so a census counts it', function ()
    local seen = {}
    for _, l in ipairs(atlas.LABELS) do seen[l] = true end
    ok(seen.unobserved, 'the new state needs a NAME, not a nil')
    store.ingest({ root = '/x', nodes = { node('A'), node('B') }, edges = {}, calls = {} })
    local c = atlas.census(store)
    eq(2, c.counts.unobserved)
    eq(0, c.counts.const, 'and it is not double-counted as const')
end)
