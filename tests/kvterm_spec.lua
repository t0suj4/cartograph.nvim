-- cartograph.algebra kv lens (kvterm.lua, CART-1379): the data adapters' JSON-like values as KEYED TERMS and back, and the
-- kv family DERIVED over it — kv_eq / kv_eq_keyed are the term algebra's equality, kv_generalize is generalize under
-- the fixed-arity rigidity decoded into kv's own record. Native kv_generalize is the ORACLE: the whole record is
-- compared (template, hole ids, kinds, value vectors, sites), because a too-general template also round-trips.
-- MEASURED 2026-10-03 on jenkins-infra (475 documents, 49 families): round trip 950/950, kv_eq 3118/3118 pairs,
-- kv_generalize via A.generalize 49/49 identical records.
local A = require('cartograph.algebra').load()

local function O(pairs_) -- O{ {'k', v}, … } keeps the written key order
    local o, keys = {}, {}
    for _, p in ipairs(pairs_) do o[p[1]] = p[2]; keys[#keys + 1] = p[1] end
    return { o = o, keys = keys }
end
local function Arr(...) return { a = { ... } } end
local function oser(v) -- ORDER-KEEPING (kv_ser sorts keys)
    local k = A.kv_kind(v)
    if k == 'obj' then local q = {}; for _, key in ipairs(v.keys) do q[#q + 1] = key .. '=' .. oser(v.o[key]) end; return '{' .. table.concat(q, ',') .. '}' end
    if k == 'arr' then local q = {}; for i, x in ipairs(v.a) do q[i] = oser(x) end; return '[' .. table.concat(q, ',') .. ']' end
    return A.kv_ser(v)
end
local function tser(t)
    if type(t) ~= 'table' then return A.kv_ser(t) end
    if t == A.KV_ABSENT then return '⊥' end
    if t.hole then return '?' .. t.hole end
    if t.opt then return '{opt ?' .. t.opt.hole .. ' ' .. tser(t.body) .. '}' end
    if t.ka then return '{ka ' .. t.keyfield .. ' ' .. tser(t.ka) .. '}' end
    if t.null then return 'null' end
    if t.o then local q = {}; for _, k in ipairs(t.keys) do q[#q + 1] = k .. '=' .. tser(t.o[k]) end; return '{' .. table.concat(q, ',') .. '}' end
    if t.a then local q = {}; for j, x in ipairs(t.a) do q[j] = tser(x) end; return '[' .. table.concat(q, ',') .. ']' end
end
local function record(R)
    local hs = {}
    for _, h in ipairs(R.holes) do
        local v = {}
        for i, x in ipairs(h.values) do v[i] = x == A.KV_ABSENT and '⊥' or (type(x) == 'boolean' and tostring(x) or A.kv_ser(x)) end
        hs[#hs + 1] = h.id .. '|' .. h.kind .. '|' .. table.concat(v, ';') .. '|' .. table.concat(h.sites, ',')
    end
    return { template = tser(R.template), holes = hs }
end
local function composed(fam)
    return A.kv_template(A.generalize(A.kv_terms(fam, { keyfield = 'name' }), { align = 'none' }), fam, {})
end

test('kv lens: a value ROUND TRIPS — key order, scalar types, null, nesting, merge-keyed lists', function ()
    local v = O({ { 'z', '1' }, { 'a', 1 }, { 'n', { null = true } }, { 't', true },
        { 'list', Arr(O({ { 'name', 'web' }, { 'port', '80' } }), O({ { 'name', 'api' } })) }, { 'plain', Arr('x', Arr()) } })
    for _, kf in ipairs({ false, 'name' }) do
        local t = A.kv_term(v, { keyfield = kf or nil })
        eq(oser(v), oser(A.term_kv(t)), 'keyfield ' .. tostring(kf))
    end
    eq('keyed', A.kv_term(v, { keyfield = 'name' }).kids[5].kids[2].align, 'a list of named objects is merge-keyed')
    eq(nil, A.kv_term(v).kids[5].kids[2].align, 'and positional with no keyfield')
    -- ★ a REPEATED name is no key (two `steps` called alike: 1,361 such lists in jenkins-infra) — keyed, both would
    -- encode as the first; the list stays positional and round-trips whole
    local steps = O({ { 'steps', Arr(O({ { 'name', 'build' }, { 'run', 'make' } }), O({ { 'name', 'build' }, { 'run', 'make test' } })) } })
    local st = A.kv_term(steps, { keyfield = 'name' })
    eq(nil, st.kids[1].kids[2].align, 'positional')
    eq(oser(steps), oser(A.term_kv(st)))
    eq(oser(steps), oser(A.term_kv(A.kv_terms({ steps, steps }, { keyfield = 'name' })[2])), 'and as a family')
end)

test('kv lens: kv_eq and kv_eq_keyed ARE the term algebra\'s equality over the lens', function ()
    local x = O({ { 'a', '1' }, { 'b', Arr(O({ { 'name', 'p' } }), O({ { 'name', 'q' } })) } })
    local y = O({ { 'b', Arr(O({ { 'name', 'q' } }), O({ { 'name', 'p' } })) }, { 'a', '1' } })
    local z = O({ { 'a', 1 }, { 'b', Arr(O({ { 'name', 'p' } }), O({ { 'name', 'q' } })) } })
    for _, c in ipairs({ { x, x }, { x, y }, { x, z }, { y, z } }) do
        eq(A.kv_eq(c[1], c[2]), A.eq(A.kv_term(c[1]), A.kv_term(c[2])), 'kv_eq')
        eq(A.kv_eq_keyed(c[1], c[2], 'name'), A.eq(A.kv_term(c[1], { keyfield = 'name' }), A.kv_term(c[2], { keyfield = 'name' })), 'kv_eq_keyed')
    end
    -- the known-nonzero halves: reordered keys are equal, a reordered NAMED list only keyed, "1" is not 1
    ok(A.eq(A.kv_term(x), A.kv_term(O({ { 'b', x.o.b }, { 'a', '1' } }))))
    ok(not A.eq(A.kv_term(x), A.kv_term(y)) and A.eq(A.kv_term(x, { keyfield = 'name' }), A.kv_term(y, { keyfield = 'name' })))
    ok(not A.eq(A.kv_term(x), A.kv_term(z)))
end)

test('kv lens: kv_generalize = generalize under the fixed-arity rigidity, decoded — the WHOLE record equals native', function ()
    local fams = {
        presence = { O({ { 'a', '1' } }), O({ { 'a', '1' }, { 'b', 'x' } }), O({ { 'a', '1' }, { 'b', 'y' } }) },
        keyed = { O({ { 'c', Arr(O({ { 'name', 'web' }, { 'img', 'w:1' } }), O({ { 'name', 'db' } })) } }),
            O({ { 'c', Arr(O({ { 'name', 'db' } }), O({ { 'name', 'web' }, { 'img', 'w:2' } })) } }) },
        -- ★ KEYEDNESS IS A FAMILY DECISION: one member's element has no name, so the list is positional in BOTH
        family_keyedness = { O({ { 'tasks', Arr(O({ { 'name', 'run' }, { 'cmd', 'make' } })) } }),
            O({ { 'tasks', Arr(O({ { 'init', 'mvn' } })) } }) },
        lengths = { O({ { 'l', Arr('1', '2') } }), O({ { 'l', Arr('1', '2', '3') } }) },
        mixed = { O({ { 'v', '1' } }), O({ { 'v', O({}) } }), O({ { 'v', { null = true } } }) },
        sharing = { O({ { 'svc', 'a' }, { 'host', 'a' } }), O({ { 'svc', 'b' }, { 'host', 'b' } }) },
        -- WRITTEN first-occurrence key order, not sorted (generalize emits keyed kids sorted)
        order = { O({ { 'zeta', '1' }, { 'alpha', '2' } }), O({ { 'mid', '3' }, { 'zeta', '9' } }) },
    }
    local names = vim.tbl_keys(fams); table.sort(names)
    for _, name in ipairs(names) do
        local fam = fams[name]
        eq(record(A.kv_generalize(fam, {})), record(composed(fam)), name)
        local R = composed(fam)
        for i = 1, #fam do ok(A.kv_eq_keyed(R.instantiate(i), fam[i]), name .. ': instance ' .. i .. ' re-instantiates') end
    end
    -- the halves the fences need to be ALIVE: a presence hole, an array hole, a mixed hole, a shared hole, a ka list
    local kinds = {}
    for _, name in ipairs(names) do for _, h in ipairs(composed(fams[name]).holes) do kinds[h.kind] = (kinds[h.kind] or 0) + 1 end end
    ok(kinds.presence and kinds.array and kinds.mixed and kinds.value, vim.inspect(kinds))
    eq(1, #composed(fams.sharing).holes, 'two sites with one value vector share ONE hole')
    ok(composed(fams.keyed).template.o.c.ka, 'a named list generalizes keyed')
    ok(composed(fams.family_keyedness).template.o.tasks.a, 'and stays positional when one member\'s element has no name')
end)

-- ★ A PLAIN LUA TABLE as a kv value (CART-1645): a PLAN (cartograph.tactic's terms) generalizes as a term — a FAMILY of
-- plans of one kind gives a template whose holes are the decisions (which corpora), and an instance of it is a plan
-- nobody wrote. Measured: two walker acceptances (five corpora / two) lifted, effect bound into the open hole, the
-- generated plan ran to done (161 s, 3314 right, 0 wrong); a value outside a PINNED hole's domain is refused
test('kv lens: a Lua table round-trips (keys sorted, the positional part under `[]`), and a plan family lifts to a template', function ()
    local T = require('cartograph.tactic').T
    local function plan(items)
        return T.seq(T.each(items, T.use('oracle', { root = T.hole('root'), floor = T.hole('floor', '%s') })), T.use('variants', { root = '/x' }))
    end
    local p = plan({ { root = '/a', floor = 1 }, { root = '/b', floor = 2 } })
    eq(p, A.kv_lua(A.term_kv(A.kv_term(A.lua_kv(p)))), 'the round trip: the same plan back')
    -- (an object's keys SORTED: two tables with the same 20 keys, inserted in opposite orders, are one term)
    local up, down, want = {}, {}, {}
    for i = 1, 20 do local k = ('k%02d'):format(i); up[k] = i; want[i] = k end
    for i = 20, 1, -1 do down[('k%02d'):format(i)] = i end
    eq(want, A.lua_kv(up).keys, 'the keys sorted, not in pairs order')
    ok(A.eq(A.kv_term(A.lua_kv(up)), A.kv_term(A.lua_kv(down))), 'insertion order is not part of the term')
    local ok_bad = pcall(A.lua_kv, { [5] = 'sparse' })
    ok(not ok_bad, 'a key neither a string nor positional refuses')
    -- the family: the same plan kind over different items -> the steps fixed, the items a sequence hole
    local fam = { A.lua_kv(plan({ { root = '/a', floor = 1 }, { root = '/b', floor = 2 }, { root = '/c', floor = 3 } })),
        A.lua_kv(plan({ { root = '/a', floor = 1 } })) }
    local g = A.generalize(A.kv_terms(fam, {}))
    local holes = {}
    for h in pairs(g.values[1]) do holes[#holes + 1] = h end
    eq(1, #holes, 'one decision: the items after the first — ' .. A.show(g.template.body))
    -- a decision -> a plan nobody wrote: the open hole takes a NEW item
    local new = A.instantiate(g.template, { [holes[1]] = A.seq({ A.kv_term(A.lua_kv({ root = '/z', floor = 9 })) }) })
    ok(new.ok, vim.inspect(new.rejected))
    local q = A.kv_lua(A.term_kv(new.term))
    eq(plan({ { root = '/a', floor = 1 }, { root = '/z', floor = 9 } }), q, 'the generated plan is the plan for those items')
end)
