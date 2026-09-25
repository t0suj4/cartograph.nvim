-- redundancy.lua: an idempotent setup step's availability over a harness's run order — what is redundant, and
-- where one copy would do (the prelude, or a unit's top level). Fixtures: tests/fixtures/redundancy/{plain,prelude}.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local redundancy = require 'cartograph.redundancy'

local FIX = vim.fn.getcwd() .. '/tests/fixtures/redundancy'

local function has_lua()
    return pcall(vim.treesitter.language.add, 'lua')
end

local memo = {}
local function analyze(dir)
    if memo[dir] then return memo[dir] end
    local data = ts.extract(FIX .. '/' .. dir)
    store.ingest(data)
    memo[dir] = redundancy.analyze(store, data)
    return memo[dir]
end
local function at(R, kind, file, line)
    for _, f in ipairs(R.findings) do
        if f.kind == kind and f.file == file and f.line == line then return f end
    end
end
local function any_at(R, file, line)
    for _, f in ipairs(R.findings) do if f.file == file and f.line == line then return f end end
end

test('redundancy: the harness is derived — the prelude defines the entry, the units call it', function ()
    if not has_lua() then skip 'no lua parser' end
    local R = analyze('plain')
    eq('run.lua', R.prelude)
    eq({ ['a_spec.lua'] = true, ['b_spec.lua'] = true, ['e_spec.lua'] = true }, R.units, 'e_spec registers no test and is still loaded')
end)

test('redundancy: within one body — an earlier dominating step makes the later one redundant; a branch does not', function ()
    if not has_lua() then skip 'no lua parser' end
    local R = analyze('plain')
    local f = at(R, 'redundant', 'a_spec.lua', 12)
    ok(f, 'a1 line 12')
    eq('earlier in this body', f.by.how)
    eq(nil, any_at(R, 'a_spec.lua', 16), 'a2: the append inside the if dominates nothing after it')
    ok(at(R, 'redundant', 'a_spec.lua', 40), 'a8: the second step in one then-branch')
    eq(nil, any_at(R, 'a_spec.lua', 42), 'a8: the else-branch step')
end)

test('redundancy: helpers — an unconditional one establishes (both directions), a conditional one does not', function ()
    if not has_lua() then skip 'no lua parser' end
    local R = analyze('plain')
    local f = at(R, 'redundant', 'a_spec.lua', 20)
    ok(f, 'a3: the append after ready()')
    ok(f.by.how:find('ready', 1, true), f.by.how)
    ok(at(R, 'redundant-via', 'a_spec.lua', 24), 'a4: ready() after a direct append')
    eq(nil, any_at(R, 'a_spec.lua', 28), 'a5: maybe() establishes nothing')
end)

test('redundancy: a sibling test does not count, another unit\'s top level does not count, its own does', function ()
    if not has_lua() then skip 'no lua parser' end
    local R = analyze('plain')
    eq(nil, any_at(R, 'a_spec.lua', 31), 'a6: a1 ran first but may have skipped')
    local b = at(R, 'redundant', 'b_spec.lua', 5)
    ok(b, 'b1: its unit top level')
    eq('unit top level', b.by.how)
    eq(nil, any_at(R, 'a_spec.lua', 36), 'a7: another directory is another fact')
end)

test('redundancy: ★ HOIST — a fact set up across units goes into the prelude, with its premises', function ()
    if not has_lua() then skip 'no lua parser' end
    local R = analyze('plain')
    local h = R.findings[1]
    eq('hoist', h.kind)
    eq('run.lua', h.to)
    eq('prelude', h.where)
    eq(3, h.units)
    eq(17, h.would_remove, 'every direct step in a, b and e: 14 + 2 + 1')
    eq('redundancy.idempotent', h.assumes[1].id)
    eq('declared', h.assumes[1].basis)
    ok(h.assumes[1].src and h.assumes[1].src:find('measured', 1, true), 'the premise cites its measurement')
    local n = 0
    for _, f in ipairs(R.findings) do if f.kind == 'hoist' then n = n + 1 end end
    eq(1, n, 'the ~/other fact appears once in one unit: no hoist')
end)

test('redundancy: a prelude step before the units load makes every unit step redundant; one after them does not', function ()
    if not has_lua() then skip 'no lua parser' end
    local R = analyze('prelude')
    local c = at(R, 'redundant', 'c_spec.lua', 3)
    ok(c, 'c1: the prelude already did it')
    eq('prelude', c.by.how)
    ok(at(R, 'redundant', 'd_spec.lua', 2), 'd1: a literal argument is the same fact as the named one')
    eq(nil, any_at(R, 'c_spec.lua', 4), 'the ~/late append is after the load loop')
    local hoists = {}
    for _, f in ipairs(R.findings) do if f.kind == 'hoist' then hoists[#hoists + 1] = f end end
    eq(1, #hoists, 'only ~/late is suggested')
    ok(hoists[1].fact.key:find('late', 1, true), hoists[1].fact.key)
end)
