-- The reorder model: per-statement effects (df direct + discharged call
-- summaries), local dataflow deps, state/world conflicts with the
-- set-once excuse, free vs opaque — the cockpit's safe-reorder MVP.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local reorder = require 'cartograph.reorder'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end

test('reorder: deps, conflicts, set-once excuse, free, opaque', function ()
    if not ready() then skip 'no lua parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat({
        'local state = {}',
        'local cache = {}',
        'local other = {}',
        'local function noisy() print("x") end',
        'local function noisy2() print("y") end',
        'local function init_cache() if not cache.k then cache.k = 1 end end',
        'local function target(x)',
        '    local a = x + 1',            -- 1: pure local def
        '    state.n = a',                -- 2: writes state, uses a (dep 1->2)
        '    init_cache()',               -- 3: set-once via call
        '    init_cache()',               -- 4: set-once again (commutes w/ 3)
        '    noisy()',                    -- 5: world
        '    noisy2()',                   -- 6: world (conflicts w/ 5)
        '    other.z = 1',                -- 7: independent state write
        '    MYSTERY()',                  -- 8: opaque
        'end',
        'return { target, noisy, noisy2, init_cache }',
    }, '\n'))
    fd:close()
    store.ingest(ts.extract(root))
    local id
    for _, n in ipairs(store.data.nodes) do
        if n.name == 'target' then id = n.id end
    end
    local m = assert(reorder.analyze(store, id))
    eq(8, #m.stmts)
    -- local dataflow dep: a defined in #1, used in #2
    local dep
    for _, d in ipairs(m.deps) do
        if d[1] == 1 and d[2] == 2 then dep = d end
    end
    ok(dep, 'local a: #1 -> #2 ordered')
    local function conflict(i, j)
        for _, c in ipairs(m.conflicts) do
            if c[1] == i and c[2] == j then return c end
        end
    end
    ok(not conflict(3, 4), 'two set-once calls to the same key COMMUTE')
    ok(conflict(5, 6) and conflict(5, 6)[3] == 'world',
        'two world-writers are order-significant')
    ok(not conflict(2, 7), 'writes to DIFFERENT vars commute')
    local isfree = {}
    for _, i in ipairs(m.free) do isfree[i] = true end
    ok(isfree[7], 'the independent write is freely movable')
    eq({ 8 }, m.opaque, 'the unresolved call is opaque, certifies nothing')
    -- the report renders without error and says what it does not model
    local lines = reorder.report(store, id)
    ok(lines[1]:find('reads through calls not modeled', 1, true),
        'the disclaimer is IN the report')

    -- the LENS carries a per-row jump map: statement rows point at their own
    -- source line, constraint rows at their first participant
    local llines, at, lm = reorder.lens(store, id)
    ok(lm and lm.node, 'the lens hands back the analyzed model')
    -- find the row for statement #1 (`local a = x + 1`, file line 8 → l0 7)
    local stmt1
    for r, spec in pairs(at) do
        if spec.i == 1 and not spec.peer then stmt1 = { r = r, spec = spec } end
    end
    ok(stmt1, 'statement #1 has a jumpable row')
    if stmt1 then
        eq(7, stmt1.spec.l0, 'statement #1 jumps to its own 0-based source line')
        ok(llines[stmt1.r]:find('#1', 1, true), 'the mapped row IS the #1 line')
    end
    -- the dep constraint row (#1 → #2) jumps to #1 and names #2 as its peer
    local depr
    for _, spec in pairs(at) do
        if spec.i == 1 and spec.peer == 2 then depr = spec end
    end
    ok(depr and depr.l0 == 7, 'the #1→#2 constraint row jumps to #1 with peer #2')
end)
