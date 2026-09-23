-- CART-1041 / CART-1040: classify an observation of one member of a KEYED family.
--
-- ★★★ THE GAP IT FILLS: positional `classify` refuses keyed nodes by name, and a keyed
-- template (a locale file, a manifest read as data) could be recovered by `kv_generalize`
-- but never compared against. Same kind vocabulary as positional, so one consumer reads both.

local A = assert(require('cartograph.algebra').load())

-- an ordered kv object from alternating key, value arguments
local function obj(...)
    local args, o, keys = { ... }, {}, {}
    for i = 1, #args, 2 do o[args[i]] = args[i + 1]; keys[#keys + 1] = args[i] end
    return { o = o, keys = keys }
end
-- `cancel` and `abort` carry the SAME text in every member: one non-linear hole, two sites.
-- `sub` is present in two members only: a presence hole.
local function family()
    return {
        obj('title', 'A', 'ok', 'Yes', 'cancel', 'No', 'abort', 'No', 'sub', obj('x', '1')),
        obj('title', 'B', 'ok', 'Ja', 'cancel', 'Nein', 'abort', 'Nein', 'sub', obj('x', '1')),
        obj('title', 'C', 'ok', 'Oui', 'cancel', 'Non', 'abort', 'Non'),
    }
end
local function with(base, key, val)
    local o, keys = {}, {}
    for _, k in ipairs(base.keys) do o[k] = base.o[k]; keys[#keys + 1] = k end
    if o[key] == nil and val ~= nil then keys[#keys + 1] = key end
    if val == nil then
        local ks = {}; for _, k in ipairs(keys) do if k ~= key then ks[#ks + 1] = k end end
        keys = ks
    end
    o[key] = val
    return { o = o, keys = keys }
end

test('kv_classify: the member\'s own unfolding is NONE, for every member (the known control)', function ()
    local R = A.kv_generalize(family(), {})
    for i = 1, 3 do eq('none', A.kv_classify(R, i, R.instantiate(i)).kind) end
end)

test('kv_classify: a changed value is VALUE, and substituting it rebuilds the observation', function ()
    local fam = family()
    local R = A.kv_generalize(fam, {})
    local C = A.kv_classify(R, 1, with(fam[1], 'title', 'A2'))
    eq('value', C.kind)
    eq(1, #C.values)
    eq('A', C.values[1].from); eq('A2', C.values[1].to)
    eq('$.title', C.values[1].sites[1])
    eq(true, C.rebuilds)
end)

test('kv_classify: ★★★ the STORE LAW — both sites of a shared hole changed is VALUE, one site is STRADDLE', function ()
    local fam = family()
    local R = A.kv_generalize(fam, {})
    local both = with(with(fam[1], 'cancel', 'Nope'), 'abort', 'Nope')
    local Cb = A.kv_classify(R, 1, both)
    eq('value', Cb.kind)
    eq(2, #Cb.values[1].sites)
    eq(true, Cb.rebuilds)
    local one = A.kv_classify(R, 1, with(fam[1], 'cancel', 'Nope'))
    eq('straddle', one.kind)
    eq('$.cancel', one.sites[1])
    eq('split', one.proposal.op)
    ok(one.why:find('1 of its 2 site', 1, true), one.why)
end)

test('kv_classify: a key appearing where the family has it OPTIONAL is a presence change — VALUE', function ()
    local fam = family()
    local R = A.kv_generalize(fam, {})
    local C = A.kv_classify(R, 3, with(fam[3], 'sub', obj('x', '1')))
    eq('value', C.kind)
    eq('presence', C.values[1].kind)
    eq(true, C.rebuilds)
end)

test('kv_classify: TEMPLATE — a fixed scalar changed, a required key removed, a new key added', function ()
    local fam = family()
    local R = A.kv_generalize(fam, {})
    local c1 = A.kv_classify(R, 1, with(fam[1], 'sub', obj('x', '2')))
    eq('template', c1.kind); eq('changed', c1.changes[1].what); eq('$.sub.x', c1.changes[1].path)
    local c2 = A.kv_classify(R, 1, with(fam[1], 'ok', nil))
    eq('template', c2.kind); eq('removed', c2.changes[1].what); eq('$.ok', c2.changes[1].path)
    local c3 = A.kv_classify(R, 1, with(fam[1], 'extra', 'new'))
    eq('template', c3.kind); eq('added', c3.changes[1].what); eq('$.extra', c3.changes[1].path)
    eq(nil, c3.rebuilds) -- a template change is not a substitution; no rebuild claim
end)

test('kv_classify: a value change and a template change together are MIXED', function ()
    local fam = family()
    local R = A.kv_generalize(fam, {})
    local C = A.kv_classify(R, 1, with(with(fam[1], 'title', 'A2'), 'extra', 'new'))
    eq('mixed', C.kind)
    eq(1, #C.values); eq(1, #C.changes)
end)

test('kv_classify: ★ a key whose PARENT was absent is not "vanished" when the parent appears without it', function ()
    -- measured on Discourse: `be` lacks the whole js.topic_entrance object; adding one child made
    -- every sibling read "vanished" (not-applicable -> absent), though nothing had been there
    local fam = {
        obj('p', obj('a', '1', 'b', '2'), 'q', 'x'),
        obj('p', obj('a', '1'), 'q', 'y'),   -- `b` is OPTIONAL inside `p`: it has a presence hole
        obj('q', 'z'),                        -- no `p` at all: b's presence is NOT APPLICABLE
    }
    local R = A.kv_generalize(fam, {})
    local C = A.kv_classify(R, 3, obj('q', 'z', 'p', obj('a', '1')))
    local vanished = 0
    for _, c in ipairs(C.values) do if c.kind == 'presence' and c.to == false then vanished = vanished + 1 end end
    for _, s in ipairs(C.straddles) do vanished = vanished + #s.sites end
    eq(0, vanished)
    ok(#C.values > 0, 'and the appearance of `p` itself IS reported: ' .. tostring(C.kind))
end)
