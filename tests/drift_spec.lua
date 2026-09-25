-- CART-1040 / CART-1041: anchor a family, observe a member, decide whether it drifted.
--
-- ★★★ THE THREE GAPS THIS CLOSES, each measured on the k8s demo and Discourse's locales:
--   1. `classify` located a change by TREE PATH ({1,1,1,7,4,…}) — now a KEY PATH;
--   2. a KEYED template could not be classified at all — `kv_classify`, same vocabulary;
--   3. the classifier names the LEG, not the verdict — priors decide, and say which one did.

local drift = require 'cartograph.drift'
local A = assert(require('cartograph.algebra').load())

local function ready()
    if not pcall(vim.treesitter.language.add, 'yaml') then skip('no yaml tree-sitter parser') end
end

local function deployment(svc, port)
    return table.concat({
        'apiVersion: apps/v1',
        'kind: Deployment',
        'metadata:',
        '  name: ' .. svc,
        'spec:',
        '  template:',
        '    spec:',
        '      serviceAccountName: ' .. svc,
        '      securityContext:',
        '        runAsNonRoot: true',
        '      containers:',
        '      - name: server',
        '        image: ' .. svc,
        '        ports:',
        '        - containerPort: ' .. port,
        '' }, '\n')
end
local function fleet()
    return {
        { id = 'alpha', text = deployment('alpha', 7001) },
        { id = 'beta', text = deployment('beta', 7002) },
        { id = 'gamma', text = deployment('gamma', 7003) },
    }
end
local function anchored()
    return assert(drift.anchor(fleet(), { lang = 'yaml', partition = false }))
end

test('drift: ★ a hole\'s sites render as KEY PATHS — the service name is one hole at three keys', function ()
    ready()
    local an = anchored()
    local F = an.families[1]
    local H = A.sites(F.T)
    local three
    for _, e in pairs(H) do if #e.sites == 3 then three = e end end
    ok(three, 'the service name is ONE non-linear hole with three sites')
    if not three then return end
    local paths = {}
    for _, s in ipairs(three.sites) do paths[#paths + 1] = drift.key_path(F.T.body, s.path) end
    table.sort(paths)
    eq('$.metadata.name', paths[1])
    eq('$.spec.template.spec.containers[1].image', paths[2])
    eq('$.spec.template.spec.serviceAccountName', paths[3])
end)

test('drift: the member\'s own text observes as NONE (the known control)', function ()
    ready()
    local an = anchored()
    eq('none', drift.observe(an, 'beta', deployment('beta', 7002)).kind)
end)

test('drift: a changed port is VALUE, located by key path', function ()
    ready()
    local o = drift.observe(anchored(), 'beta', deployment('beta', 7999))
    eq('value', o.kind)
    eq(1, #o.changes)
    eq('value', o.changes[1].leg)
    ok(o.changes[1].path:find('containerPort', 1, true), tostring(o.changes[1].path))
end)

test('drift: a flipped constant is TEMPLATE at its key path', function ()
    ready()
    local o = drift.observe(anchored(), 'beta',
        (deployment('beta', 7002):gsub('runAsNonRoot: true', 'runAsNonRoot: false')))
    eq('template', o.kind)
    ok(o.changes[1].path:find('securityContext.runAsNonRoot', 1, true), tostring(o.changes[1].path))
end)

test('drift: ★★ an image tag breaks "image == name" — STRADDLE at the image key', function ()
    ready()
    local o = drift.observe(anchored(), 'beta',
        (deployment('beta', 7002):gsub('image: beta', 'image: beta:v2')))
    eq('straddle', o.kind)
    local st
    for _, c in ipairs(o.changes) do if c.leg == 'straddle' then st = c end end
    ok(st, 'a straddle change is reported')
    eq('$.spec.template.spec.containers[1].image', st and st.path)
end)

test('drift: a non-member is refused by name', function ()
    ready()
    local o, why = drift.observe(anchored(), 'delta', deployment('delta', 1))
    eq(nil, o)
    ok(why:find('not a member', 1, true), why)
end)

-- ── the verdict layer ──────────────────────────────────────────────────────────
local function one(leg, what, path, to) return { id = 'x', changes = { { leg = leg, what = what, path = path, to = to } } } end

test('drift: VERDICT — declared decides intended vs drift, and says so', function ()
    local declared = function (_, path) return path == '$.a' and 'new' or nil end
    eq('intended', drift.verdict(one('value', 'changed', '$.a', 'new'), { declared = declared })[1].verdict)
    local r = drift.verdict(one('value', 'changed', '$.a', 'other'), { declared = declared })[1]
    eq('drift', r.verdict); eq('declared', r.prior)
    ok(r.why:find('declared new, observed other', 1, true), r.why)
end)

test('drift: VERDICT — an authorised plan outranks the declaration', function ()
    local rows = drift.verdict(one('value', 'changed', '$.a', 'other'), {
        authorised = function () return true end,
        declared = function () return 'new' end })
    eq('intended', rows[1].verdict); eq('authorised', rows[1].prior)
end)

test('drift: VERDICT — on a static row, history tells LAG from LEFTOVER, which frequency got backwards', function ()
    local history = function (path) return ({ ['$.new'] = 'new', ['$.old'] = 'removed' })[path] end
    eq('lag', drift.verdict(one('declared', 'missing', '$.new'), { history = history })[1].verdict)
    eq('leftover', drift.verdict(one('declared', 'extra', '$.old'), { history = history })[1].verdict)
end)

test('drift: VERDICT — ★ an OBSERVED vanish is a regression (drift), never lag: the member HAD the key', function ()
    -- the acceptance run's first expectation was wrong: lag means NEVER HAD IT, and an observed
    -- change against the anchor means the member had it at anchor time and lost it
    local declared = function (_, path) return ({ ['$.new'] = 'true' })[path] end
    local history = function (path) return ({ ['$.new'] = 'new' })[path] end
    local r = drift.verdict(one('value', 'vanished', '$.new'), { declared = declared, history = history })[1]
    eq('drift', r.verdict); eq('declared', r.prior)
    -- and an OBSERVED change still answers to a plan: an authorised removal is intended
    local ra = drift.verdict(one('value', 'vanished', '$.new'), { authorised = function () return true end,
        declared = declared, history = history })[1]
    eq('intended', ra.verdict); eq('authorised', ra.prior)
end)

test('drift: ★★ AGAINST THE DECLARATION — missing NEW keys are lag, missing OLD keys drift, kept REMOVED keys leftover', function ()
    local function obj(...)
        local args, o, keys = { ... }, {}, {}
        for i = 1, #args, 2 do o[args[i]] = args[i + 1]; keys[#keys + 1] = args[i] end
        return { o = o, keys = keys }
    end
    local an = drift.anchor({
        { id = 'en', value = obj('old', 'O', 'new', 'N') },
        { id = 'de', value = obj('gone', 'G') },
    }, { keyed = true })
    local o = drift.against_declared(an, 'de', obj('old', 'O', 'new', 'N'))
    local history = function (path) return ({ ['$.new'] = 'new', ['$.gone'] = 'removed' })[path] end
    local by = {}
    for _, r in ipairs(drift.verdict(o, { history = history })) do by[r.change.path] = r end
    eq('lag', by['$.new'].verdict)
    eq('drift', by['$.old'].verdict)       -- old and still missing: a gap, by the declaration
    eq('leftover', by['$.gone'].verdict)
    eq('missing', by['$.new'].change.what); eq('extra', by['$.gone'].change.what)
end)

test('drift: VERDICT — a straddle with no prior is SUSPECT (invariant); anything else UNDECIDED', function ()
    local s = drift.verdict(one('straddle', 'broke a shared value', '$.img'), {})[1]
    eq('suspect', s.verdict); eq('invariant', s.prior)
    local u = drift.verdict(one('value', 'changed', '$.a', 'b'), {})[1]
    eq('undecided', u.verdict); eq(nil, u.prior)
end)

-- ── keyed: the parameter prior, measured on plural forms ─────────────────────
local function obj(...)
    local args, o, keys = { ... }, {}, {}
    for i = 1, #args, 2 do o[args[i]] = args[i + 1]; keys[#keys + 1] = args[i] end
    return { o = o, keys = keys }
end
local function plural(cats)
    local args = {}
    for _, c in ipairs(cats) do args[#args + 1] = c; args[#args + 1] = c .. '!' end
    return obj(unpack(args))
end
local function locale(cats) return obj('a', plural(cats), 'b', plural(cats)) end

test('drift: ★★ KEYED — a locale adopting a plural form EVERYWHERE is a PARAMETER; at one parent it is not', function ()
    local an = drift.anchor({
        { id = 'en', value = locale { 'one', 'other' } },
        { id = 'ru', value = locale { 'one', 'few', 'many', 'other' } },
        { id = 'ja', value = locale { 'other' } },
        { id = 'he', value = locale { 'one', 'two', 'many', 'other' } },
        { id = 'pt', value = locale { 'one', 'other' } },
    }, { keyed = true })
    -- ⚠ WITHOUT `he`, `few` and `many` occur in exactly the same members, so the store law
    -- gives all four of their presence sites ONE hole, and gaining `many` alone is a true
    -- straddle ("few and many always come together here") — the first cut of this test.
    -- pt gains `many` at BOTH parents: one presence hole (a.many and b.many share ru+he)
    local both = locale { 'one', 'many', 'other' }
    local o = drift.observe(an, 'pt', both)
    eq('value', o.kind)
    local rows = drift.verdict(o, { parameter = drift.shape_consistent(an, both, { min_parents = 2 }) })
    eq('parameter', rows[1].verdict)
    -- pt gains `many` at ONE parent only: the shared presence hole straddles, and the
    -- member is no longer consistent with itself, so the prior does NOT call it a parameter
    local half = obj('a', plural { 'one', 'many', 'other' }, 'b', plural { 'one', 'other' })
    local o2 = drift.observe(an, 'pt', half)
    eq('straddle', o2.kind)
    local r2 = drift.verdict(o2, { parameter = drift.shape_consistent(an, half, { min_parents = 2 }) })
    eq('suspect', r2[1].verdict)
end)

test('drift: the parameter prior DECLINES below its evidence threshold (default: conservative)', function ()
    local function obj(...)
        local args, o, keys = { ... }, {}, {}
        for i = 1, #args, 2 do o[args[i]] = args[i + 1]; keys[#keys + 1] = args[i] end
        return { o = o, keys = keys }
    end
    local v = obj('a', obj('one', '1', 'other', 'o'), 'b', obj('one', '1', 'other', 'o'))
    local an = drift.anchor({ { id = 'x', value = v }, { id = 'y', value = v } }, { keyed = true })
    -- two parents of the shape: below the default, so the prior says nothing
    eq(nil, drift.shape_consistent(an, v)('x', { path = '$.a.one' }))
    eq(true, drift.shape_consistent(an, v, { min_parents = 2 })('x', { path = '$.a.one' }))
end)

test('drift: ★ KEYED — dropping ONE of two keys that always travel together is a presence straddle read as VANISHED', function ()
    local function obj(...)
        local args, o, keys = { ... }, {}, {}
        for i = 1, #args, 2 do o[args[i]] = args[i + 1]; keys[#keys + 1] = args[i] end
        return { o = o, keys = keys }
    end
    -- x and y are present in exactly the same members: one presence hole, two sites
    local an = drift.anchor({
        { id = 'en', value = obj('x', 'X', 'y', 'Y', 'z', 'Z') },
        { id = 'de', value = obj('x', 'X2', 'y', 'Y2', 'z', 'Z2') },
        { id = 'ja', value = obj('z', 'Z3') },
    }, { keyed = true })
    local o = drift.observe(an, 'de', obj('y', 'Y2', 'z', 'Z2'))
    eq('straddle', o.kind)
    local st
    for _, c in ipairs(o.changes) do if c.leg == 'straddle' then st = c end end
    eq('presence', st.hole_kind); eq('vanished', st.what); eq('$.x', st.path)
    -- existence is what `en` declares, so the declared prior decides it: a regression
    local r
    for _, row in ipairs(drift.verdict(o, { declared = function (_, path) return path == '$.x' and 'true' or nil end })) do
        if row.change.leg == 'straddle' then r = row end
    end
    eq('drift', r.verdict); eq('declared', r.prior)
end)

test('drift: KEYED — a key APPEARING is reported once (its text going absent -> value is part of the appearance)', function ()
    local function obj(...)
        local args, o, keys = { ... }, {}, {}
        for i = 1, #args, 2 do o[args[i]] = args[i + 1]; keys[#keys + 1] = args[i] end
        return { o = o, keys = keys }
    end
    local an = drift.anchor({
        { id = 'en', value = obj('a', '1', 'k', 'K1') },
        { id = 'de', value = obj('a', '2', 'k', 'K2') },
        { id = 'ja', value = obj('a', '3') },
    }, { keyed = true })
    local o = drift.observe(an, 'ja', obj('a', '3', 'k', 'K3'))
    eq(1, #o.changes)
    eq('appeared', o.changes[1].what)
end)
