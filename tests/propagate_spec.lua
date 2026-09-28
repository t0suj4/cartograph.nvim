-- txn_plan_propagate (CART-1152): an edit on ONE member of a near-clone family, carried to the others through the
-- journal. The oracle is the RUNTIME, not the renderer: the written module is loaded and its functions are called —
-- members in scope compute with the new value, members outside it compute exactly as before, and each keeps its own
-- other values.

local store = require 'cartograph.store'
local ts = require 'cartograph.providers.treesitter'
local txn = require 'cartograph.txn'
local propagate = require 'cartograph.propagate'
local tactic = require 'cartograph.tactic'

local function ready()
    return pcall(vim.treesitter.get_string_parser, '', 'lua') and require('cartograph.algebra').available()
end

--- one member: `acc * mul`, returned with a tail; sized for the family detector's default population
local function body(n, mul, tail, fn, note)
    return ([[
function M.g%s(t)
    local acc = 0
    local seen = {}
    for i = 1, #t do acc = acc + t[i] * %s end%s
    local s = tostring(acc)
    local u = string.%s(s)
    seen[u] = true
    local pad = string.rep("-", #u)
    local out = pad .. u
    return out .. "%s"
end
]]):format(n, mul, note and ('\n    -- ' .. note) or '', fn or 'upper', tail)
end

local root
local function project(bodies)
    root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/fe.lua', 'w'))
    fd:write('local M = {}\n' .. table.concat(bodies) .. 'return M\n'); fd:close()
    store.ingest(ts.extract(root))
end
local function id(name) for _, n in ipairs(store.data.nodes) do if n.name == name then return n.id end end end
local function load() return dofile(root .. '/fe.lua') end
local function disk() local fd = assert(io.open(root .. '/fe.lua')); local s = fd:read('a'); fd:close(); return s end
local function kinds(plan) local k = {}; for _, h in ipairs(require('cartograph.hazard').plain(plan.hazards)) do k[#k + 1] = h.kind end; return k end

test('propagate: a VALUE edit with scope = all reaches every member, each keeping its own other values (runtime oracle)', function ()
    if not ready() then skip 'no lua parser or algebra' end
    project { body(1, 1, 1), body(2, 2, 2), body(3, 3, 3) }
    local plan, why = propagate.plan(store, { node = id('M.g1'), text = body(1, 9, 1), scope = 'all' })
    ok(plan, tostring(why))
    eq('value', plan.kind); eq(3, #plan.members)
    ok(txn.apply(store, plan), 'applied')
    local M = load()
    -- sum{1,2} * 9 = 27 in every member; the tails stay each member's own
    eq('--271', M.g1({ 1, 2 })); eq('--272', M.g2({ 1, 2 })); eq('--273', M.g3({ 1, 2 }))
end)

test('propagate: without a scope the plan is the ORIGIN ONLY, and the wider scope is a DECISION hazard with a fix', function ()
    if not ready() then skip 'no lua parser or algebra' end
    project { body(1, 1, 1), body(2, 2, 2), body(3, 3, 3) }
    local plan = assert(propagate.plan(store, { node = id('M.g1'), text = body(1, 9, 1) }))
    eq({ 'M.g1' }, plan.members)
    eq({ 'propagate-scope' }, kinds(plan), 'only `all` widens it: the old value 1 is held by g1 alone, so `class` is not offered')
    local fx = require('cartograph.hazard').fixes(plan)
    eq('txn_plan_propagate', fx[1] and fx[1].verb); eq('all', fx[1] and fx[1].args.scope)
    ok(txn.apply(store, plan))
    local M = load()
    eq('--271', M.g1({ 1, 2 })); eq('-62', M.g2({ 1, 2 }), 'g2 untouched: still * 2 (one pad dash per digit)'); eq('-93', M.g3({ 1, 2 }))
end)

test('propagate: scope = class reaches exactly the members that held the OLD value', function ()
    if not ready() then skip 'no lua parser or algebra' end
    project { body(1, 1, 'a'), body(2, 1, 'b'), body(3, 3, 'c') }
    local plan = assert(propagate.plan(store, { node = id('M.g1'), text = body(1, 9, 'a'), scope = 'class' }))
    eq({ 'M.g1', 'M.g2' }, plan.members)
    ok(txn.apply(store, plan))
    local M = load()
    eq('--27a', M.g1({ 1, 2 })); eq('--27b', M.g2({ 1, 2 })); eq('-9c', M.g3({ 1, 2 }), 'g3 held 3, not the old value: untouched')
end)

test('propagate: a TEMPLATE edit migrates the fixed part, keeping each member\'s NAME and values', function ()
    if not ready() then skip 'no lua parser or algebra' end
    project { body(1, 1, 1), body(2, 2, 2), body(3, 3, 3) }
    local plan, why = propagate.plan(store, { node = id('M.g1'), text = body(1, 1, 1, 'lower'), scope = 'clean' })
    ok(plan, tostring(why))
    ok(plan.kind == 'template' or plan.kind == 'mixed', plan.kind)
    eq(3, #plan.members)
    ok(txn.apply(store, plan))
    local s = disk()
    local _, lowers = s:gsub('string%.lower', '')
    eq(3, lowers, 'every member takes the new fixed part')
    for n = 1, 3 do ok(s:find(('function M.g%d%%('):format(n)), 'g' .. n .. ' keeps its own name') end
    local M = load()
    eq('-62', M.g2({ 1, 2 }), 'and its own values: sum 3 * 2 = 6')
end)

test('propagate: a member whose surface outside the holes differs from the origin keeps its text — named as residue', function ()
    if not ready() then skip 'no lua parser or algebra' end
    project { body(1, 1, 1), body(2, 2, 2), body(3, 3, 3, nil, 'a comment only g3 has') }
    local plan = assert(propagate.plan(store, { node = id('M.g1'), text = body(1, 1, 1, 'lower'), scope = 'clean' }))
    local seen
    for _, h in ipairs(require('cartograph.hazard').plain(plan.hazards)) do
        if h.kind == 'not-propagated' and h.text:find('M.g3', 1, true) then seen = h end
    end
    ok(seen and seen.text:find('differs from the origin', 1, true), vim.inspect(plan.hazards))
    ok(not vim.tbl_contains(plan.members, 'M.g3'), 'g3 is not written — its comment would have been overwritten')
    ok(txn.apply(store, plan))
    ok(disk():find('a comment only g3 has', 1, true), 'and the comment survives')
end)

test('propagate: an edit the family does not see is EMPTY, and a member with no family is not propagate\'s', function ()
    if not ready() then skip 'no lua parser or algebra' end
    project { body(1, 1, 1), body(2, 2, 2), body(3, 3, 3) }
    local p, why, class = propagate.plan(store, { node = id('M.g1'), text = body(1, 1, 1) })
    eq(nil, p); eq('empty', class); ok(why:find('no longer be derived', 1, true), why)
    project { 'function M.g1(x) return x end\n' }
    local q, qwhy, qclass = propagate.plan(store, { node = id('M.g1'), text = 'function M.g1(x) return 1 end' })
    eq(nil, q); eq('ill-posed', qclass); ok(qwhy:find('replace', 1, true), qwhy)
end)

test('propagate: in a TACTIC the scope decision stops the run BEFORE anything is written; answered, it applies; re-run is empty', function ()
    if not ready() then skip 'no lua parser or algebra' end
    project { body(1, 1, 1), body(2, 2, 2), body(3, 3, 3) }
    local before = disk()
    local ref = store.ref_of(id('M.g1'))
    local r = tactic.run(store, tactic.T.step('propagate', { ref = ref, text = body(1, 9, 1) }), { apply = true })
    eq('stopped', r.status); eq('propagate-scope', r.options and r.options[1] and r.options[1].kind)
    eq(before, disk(), 'nothing written: once g1 holds the edit, the wider scope could not be derived')
    local term = tactic.T.step('propagate', { ref = ref, text = body(1, 9, 1), scope = 'all' })
    local done = tactic.run(store, term, { apply = true })
    eq('done', done.status, tostring(done.why)); eq(1, done.applied)
    local again = tactic.run(store, term, { apply = true })
    eq('done', again.status); eq(0, again.applied, 'the re-run classifies as none: empty')
end)

test('propagate: a render is checked against its PREDICTED values — a wrong prediction refuses rather than writes', function ()
    if not ready() then skip 'no lua parser or algebra' end
    project { body(1, 1, 1), body(2, 2, 2), body(3, 3, 3) }
    local clones = require 'cartograph.clones'
    local fam = assert(clones.family_of(store, id('M.g1')))
    local P = assert(clones.family_propagate(fam, 1, body(1, 9, 1), store))
    -- g2 rendered unchanged, but PREDICTED to hold g1's values: the reparse cannot match, so it refuses
    local r, why = clones.family_member_text(fam, P, 1, body(1, 9, 1), 2, store, { holes = {}, template = false, values = fam.values[1] })
    eq(nil, r); ok(tostring(why):find('predicted', 1, true), tostring(why))
    local ok2 = clones.family_member_text(fam, P, 1, body(1, 9, 1), 2, store, { holes = {}, template = false, values = fam.values[2] })
    ok(ok2 and ok2.text, 'and the true prediction renders')
end)
