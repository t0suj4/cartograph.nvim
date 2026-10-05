-- cartograph.mixalg (CART-1279, S3): match specialized to a template = a COMPILED MATCHER — held to A.match itself on
-- every projected subterm of real files the template's rule is tried on (the luajs rules are the shipped templates)
local MA = require 'cartograph.mixalg'
local rules = require 'cartograph.luajs.rules'
local R = require 'cartograph.algebraread'
local A = require('cartograph.algebra').load()

local function ready() if not pcall(vim.treesitter.get_string_parser, '', 'lua') then skip 'no lua parser' end end

-- the projected subterms of a few of this repository's files, by the rules' index key
local function population()
    local by = {}
    for _, rel in ipairs({ 'lua/cartograph/mix.lua', 'lua/cartograph/luajs/rules.lua' }) do
        local path = vim.api.nvim_get_runtime_file(rel, false)[1]
        local term = assert(R.read(io.open(path):read('a'), 'lua'))
        local memo = {}
        local function walk(t)
            local p = rules.project(t, memo)
            local h = rules.head(p)
            by[h] = by[h] or {}
            by[h][#by[h] + 1] = p
            for _, c in ipairs(t.kids or {}) do if c.k ~= 'lit' then walk(c) end end
        end
        walk(term)
    end
    return by
end

test('mixalg: match specialized to a luajs rule\'s template is a COMPILED MATCHER — equal to A.match on every subject the rule is tried on, no template left', function ()
    ready()
    local by = population()
    local all = rules.all()
    local checked = 0
    for _, want in ipairs({ 'nil', 'a.f', 'a + b', 'not a', 'return', 'return a' }) do
        local c
        for _, r in ipairs(all) do if r.lua == want then c = r end end
        ok(c, 'rule ' .. want)
        local compiled, text = MA.compile_match(c.lhs)
        local subj = by[c.key] or {}
        ok(#subj > 0, want .. ': subjects in the population')
        for _, p in ipairs(subj) do
            eq(A.match(c.lhs, p), compiled(p), ('%s on a %s'):format(want, p.k))
            checked = checked + 1
        end
        -- (a subject of ANOTHER kind is refused by both alike)
        local other = by[all[1].key ~= c.key and all[1].key or all[2].key][1]
        eq(A.match(c.lhs, other), compiled(other), want .. ' on another kind')
        ok(not text:find('%f[%w_]T_%d+%f[^%w_]'), want .. ': the template variable T is gone from the residual')
    end
    ok(checked > 500, checked .. ' subjects compared')
end)

test('mixalg: the assembled closure of match is a mix program — every definition lowers, none refused', function ()
    ready()
    local text, order = MA.program('M.match')
    local got = {}
    require('cartograph.mix').lower(assert(R.read(text, 'lua')), { collect = got })
    eq({}, got)
    ok(#order >= 25, #order .. ' definitions in the closure')
    eq('M.match', order[1])
end)

test('mixalg: a derivation\'s closure follows its FILE\'S MODULE TABLE — D.apply in derive.lua reaches D.sites, mangled to an identifier, and lowers with nothing refused (CART-1372)', function ()
    ready()
    local text, order = MA.program('derive.lua::D.apply')
    local has = {}
    for _, k in ipairs(order) do has[k] = true end
    ok(has['derive.lua::D.sites'], 'D.sites in the closure: ' .. table.concat(order, ' '))
    ok(text:find('local function derive__D_sites', 1, true) ~= nil, 'D.sites assembled as derive__D_sites')
    ok(text:find('derive__D_sites(T)', 1, true) ~= nil, 'the call to D.sites rewritten to its mangled name')
    local got = {}
    require('cartograph.mix').lower(assert(R.read(text, 'lua')), { collect = got })
    eq({}, got)
end)

test('mixalg: an UNFOLD is specialized ONCE per configuration — a statement-list template compiles in a few thousand steps (it ran out of 5e6 before CART-1455) and equals A.match on real declarations', function ()
    ready()
    local rules_ = assert(require('cartograph.byexample').learn('local function f()\n  a()\n  b()\nend', 'local function f()\n  a()\n  x()\n  b()\nend', 'lua'))
    local T = rules_[1].lhs
    local m, _, stats = MA.compile_match(T, { budget = 2e5 })
    ok(stats.unfold_steps < 1e5, stats.unfold_steps .. ' unfold steps')
    local src = io.open('lua/cartograph/mixalg.lua'):read('a'):gsub('\nreturn M%s*$', '\n') .. 'local function g()\n  a()\n  b()\nend\n'
    local subjects, hits = {}, 0
    local function walk(t)
        if t.k == 'function_declaration' then subjects[#subjects + 1] = t end
        for _, c in ipairs(t.kids or {}) do walk(c) end
    end
    walk(assert(R.read(src, 'lua')))
    ok(#subjects > 5, #subjects .. ' declarations')
    for _, s in ipairs(subjects) do
        local want = A.match(T, s)
        eq(want, m(s))
        if want.ok then hits = hits + 1 end
    end
    eq(1, hits, 'the one two-statement function matches')
end)

test('mixalg: a continuation that keeps GROWING is made DYNAMIC — a statement template whose chain nested past 20 compiles, and equals A.match on real declarations (CART-1456)', function ()
    ready()
    -- (`local ?1 = 1 return ?1`: go_kids adds a continuation per template child, trivia included — refused before)
    local rules_ = assert(require('cartograph.byexample').learn('local function f()\n  local a = 1\n  return a\nend', 'local function f()\n  local a = 1\n  a = a + 1\n  return a\nend', 'lua'))
    local T = rules_[1].lhs
    local m = MA.compile_match(T, { budget = 2e5 })
    local src = io.open('lua/cartograph/mixalg.lua'):read('a'):gsub('\nreturn M%s*$', '\n') .. 'local function g()\n  local q = 1\n  return q\nend\n'
    local hits, n = 0, 0
    local function walk(t)
        if t.k == T.body.k then -- (the rule's own root kind)
            n = n + 1
            local want = A.match(T, t)
            eq(want, m(t))
            if want.ok then hits = hits + 1 end
        end
        for _, c in ipairs(t.kids or {}) do walk(c) end
    end
    walk(assert(R.read(src, 'lua')))
    ok(n > 5, n .. ' declarations'); eq(1, hits)
end)

test('mixalg: a configuration whose KEY cannot be formed — a static TEMPLATE nested past 20 — refuses FAST, by name (CART-1455)', function ()
    ready()
    -- (no closure to make dynamic: the template itself is the deep static value. Under this budget the old behaviour,
    -- rollback and retry, ran out of BUDGET instead of naming the key)
    local src = 'local x = ' .. string.rep('(', 25) .. 'y' .. string.rep(')', 25)
    local T = A.template(assert(R.read(src, 'lua')))
    local okc, e = pcall(MA.compile_match, T, { budget = 2e5 })
    eq(false, okc)
    ok(type(e) == 'table' and tostring(e.refusal):find('nested deeper than', 1, true), vim.inspect(e))
end)

test('mixalg: the assembled program keeps a LINE MAP, so a compiled matcher\'s static error message names the ALGEBRA\'s position, byte for byte (CART-1458)', function ()
    ready()
    local text, _, lines = MA.program('M.match')
    -- (every line of the program maps to a line of an algebra file holding the same text, renames aside)
    local n, same = 0, 0
    for l, src in ipairs(vim.split(text, '\n')) do
        local m = lines[l]
        if m and src:match('%S') then
            n = n + 1
            local file = io.open(vim.fn.glob('lua/cartograph/algebra/' .. m.src:match('algebra/(.*)$'))):read('a')
            local orig = vim.split(file, '\n')[m.line] or ''
            if orig:gsub('%s', ''):sub(1, 8) == src:gsub('%s', ''):sub(1, 8) or src:match('^local function') then same = same + 1 end
        end
    end
    ok(n > 300 and same / n > 0.9, ('%d of %d mapped lines start like their original'):format(same, n))
    -- (the `nil` rule's matcher holds a refusal raised by core's M.keys at compile time: the original's own prefix)
    local lhs
    for _, r in ipairs(rules.all()) do if r.lua == 'nil' then lhs = r.lhs end end
    local _, residual = MA.compile_match(lhs)
    local _, orig = pcall(A.keys, { k = 'nil', align = 'keyed', kids = { { k = 'lit', v = 1 } } })
    local prefix = tostring(orig):match('^(.-:%d+: )')
    ok(prefix and residual:find(prefix .. 'keyed nil', 1, true), tostring(prefix))
end)

test('mixalg: a KEYED template compiles to a matcher EQUAL to A.match on keyed subjects — missing and extra keys, keyed lists, deep refusal paths (CART-1460, CART-1461)', function ()
    ready()
    -- (the luajs population has no keyed node and no refusal deeper than two steps: compiled keyed matching was a
    -- different program — `key` rewritten to a function — and every deep path lost its middle, both unseen)
    -- (plain tables as kv values: objects { o, keys }, lists { a }; `svc` merge-keyed by its `id`)
    local function kv(x)
        if type(x) ~= 'table' then return x end
        if x[1] ~= nil then local a = {}; for i, e in ipairs(x) do a[i] = kv(e) end; return { a = a } end
        local o, keys = {}, {}
        for k, v in pairs(x) do o[k] = kv(v); keys[#keys + 1] = k end
        table.sort(keys)
        return { o = o, keys = keys }
    end
    local function K(v) return A.kv_term(kv(v), { keyfield = 'id' }) end
    local function cfg(name, port, deeper, tags)
        return { name = name, port = port, tags = tags, sub = { deep = { deeper = deeper } }, svc = { { id = 'a', w = port }, { id = 'b', w = 1 } } }
    end
    -- (the template: one config, its port a hole — keyed objects three deep, a keyed list)
    local function holed(t)
        if t.k == 'lit' and tostring(t.v) == '80' then return A.hole('p') end
        if not t.kids then return t end
        local kids = {}
        for i, c in ipairs(t.kids) do kids[i] = holed(c) end
        return A.rebuild(t, kids)
    end
    local T = A.template(holed(K(cfg('a', 80, 1, { 'x', 'y' }))))
    local m, _, stats = MA.compile_match(T)
    ok(stats.functions > 1, 'compiled')
    local subjects = {
        K(cfg('a', 90, 1, { 'x', 'y' })), K(cfg('a', 90, 3, { 'x', 'y' })), K(cfg('a', 90, { 1 }, { 'x', 'y' })), K(cfg('a', 9, 1, { 'x' })),
        K(cfg('b', 90, 1, { 'x', 'y' })),
        K({ name = 'a', port = 1, tags = { 'x', 'y' }, sub = { deep = { other = 1 } }, svc = { { id = 'a', w = 1 } } }),
        K({ name = 'a', port = 1, tags = { 'x', 'y' }, sub = { deep = { deeper = 1, extra = 2 } }, svc = { { id = 'a', w = 1 }, { id = 'b', w = 1 } } }),
        K({ name = 'a', port = 2, tags = { 'x', 'y' }, sub = { deep = { deeper = 1 } }, svc = { { id = 'a', w = 3 }, { id = 'b', w = 1 } } }),
        K({}), K({ 1, 2, 3 }), K('x'),
    }
    local deep = 0
    for i, s in ipairs(subjects) do
        local want = A.match(T, s)
        eq(want, m(s), 'subject ' .. i)
        if want.refusal and select(2, tostring(want.refusal.at):gsub('/', '')) >= 2 then deep = deep + 1 end
    end
    ok(deep >= 2, deep .. ' refusals three or more steps deep')
end)

test('mixalg: SPECULATION — compiled under "no subject node is keyed", a matcher is smaller and equal to A.match on code; a keyed subject DEOPTIMIZES (CART-1463)', function ()
    ready()
    local ASSUME = require('cartograph.compiledverb').ASSUME
    local by = population()
    for _, want in ipairs({ 'nil', 'a.f', 'return a' }) do
        local c
        for _, r in ipairs(rules.all()) do if r.lua == want then c = r end end
        local _, exact = MA.compile_match(c.lhs)
        local m, spec = MA.compile_match(c.lhs, { assume = ASSUME })
        ok(#spec < #exact * 0.8, ('%s: %d -> %d bytes'):format(want, #exact, #spec))
        ok(spec:find('MIXDEOPT()', 1, true), want .. ': the assumption is guarded')
        for _, p in ipairs(by[c.key] or {}) do eq(A.match(c.lhs, p), m(p), want) end
        -- (a keyed subject: the guard fires — the caller runs the original)
        local okm, e = pcall(m, { k = c.lhs.body.k, align = 'keyed', kids = {} })
        eq(false, okm); eq(MA.DEOPT, e)
    end
    -- (a deopt a residual `pcall` swallowed is still raised: the flag is checked after the call)
    local f = MA.load_match('return function (I) local ok = pcall(function () MIXDEOPT() end); return { ok = ok } end', {})
    local okf, ef = pcall(f, {})
    eq(false, okf); eq(MA.DEOPT, ef)
end)

test('mixalg: a compiled matcher comes with its SOURCE MAP — residual lines map into the algebra\'s own files (CART-1459)', function ()
    ready()
    local c
    for _, r in ipairs(rules.all()) do if r.lua == 'a.f' then c = r end end
    local _, text, _, _, map = MA.compile_match(c.lhs)
    local n, into = 0, 0
    for line, w in pairs(map) do n = n + 1; if tostring(w):find('algebra/[%w_]+%.lua:%d+$') then into = into + 1 end end
    ok(n > 50 and into == n, ('%d of %d mapped lines point into algebra/'):format(into, n))
end)

test('mixalg: a closure\'s FILE-LEVEL LOCALS are carried from the loaded code — a constant inlined, a table KNOWN, a written one free unless snapshot (CART-1374)', function ()
    ready()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/lua/mxk1374', 'p')
    local path = dir .. '/lua/mxk1374/fix.lua'
    local fd = assert(io.open(path, 'w'))
    fd:write(table.concat({
        'local M = {}',
        'local SEP = "-"',
        'local RULES = { width = 3, name = "r" }',
        'local cache = nil',
        'function M.f(a)',
        '  return a .. SEP .. RULES.width .. tostring(cache)',
        'end',
        'function M.warm() cache = 7 end',
        'function M.g(a) return RULES[a] end',
        'return M', '' }, '\n'))
    fd:close()
    local saved = package.path
    package.path = dir .. '/lua/?.lua;' .. package.path
    local MX = require 'cartograph.mix'
    local okall, err = pcall(function ()
        local text, _, _, knowns, report = MA.program('M.f', { path })
        ok(text:find('"-"', 1, true) and not text:find('SEP', 1, true), 'the never-written scalar is inlined: ' .. text)
        eq(3, knowns.fix__RULES.width); eq(3, knowns['fix__RULES.width'])
        eq({ 'fix.lua::SEP', 'fix.lua::RULES' }, report.known)
        eq({ 'fix.lua::cache' }, report.free)
        ok(text:find('tostring(cache)', 1, true), 'a WRITTEN local stays free without a snapshot')
        -- (mix specializes it with the knowns as globals, and refuses it without them: the carried table is what it needed)
        local prog = MX.lower(assert(R.read(text, 'lua')))
        local okn = pcall(MX.specialize, prog, 'M_f', { 'D' }, {}, { budget = 2e5 })
        eq(false, okn)
        require('mxk1374.fix').warm()
        local snap, _, _, sk, sr = MA.program('M.f', { path }, { snapshot = true })
        eq({ 'fix.lua::cache' }, sr.snapshots); eq({}, sr.free)
        local sprog = MX.lower(assert(R.read(snap, 'lua')))
        local res = MX.specialize(sprog, 'M_f', { 'D' }, {}, { budget = 2e5, globals = sk })
        local F = require 'cartograph.mixfn'
        local f = assert(load(MX.print(res, sprog.where), 'residual', 't', F.env(res.pool, sk)))()
        eq('x-37', f('x'))
        -- (a known read by DYNAMIC code is residualized as its path — `fix__RULES[a]` — so the residual loads with
        -- the knowns in its environment: mixfn.env)
        local gt, _, _, gk = MA.program('M.g', { path })
        local gprog = MX.lower(assert(R.read(gt, 'lua')))
        local gres = MX.specialize(gprog, 'M_g', { 'D' }, {}, { budget = 2e5, globals = gk })
        local g = assert(load(MX.print(gres, gprog.where), 'residual', 't', F.env(gres.pool, gk)))()
        eq(3, g('width')); eq('r', g('name'))
    end)
    package.path = saved
    package.loaded['mxk1374.fix'] = nil
    vim.fn.delete(dir, 'rf')
    if not okall then error(err, 0) end
end)

test('mixalg: a closure mix cannot lower is REFUSED by name, never a Lua error — transplant crashed lowering on an empty block before CART-1335', function ()
    ready()
    local text = MA.program('M.transplant')
    local got = {}
    local okl, e = pcall(require('cartograph.mix').lower, assert(R.read(text, 'lua')), { collect = got })
    ok(okl or (type(e) == 'table' and e.refusal ~= nil), 'a refusal or a lowering, not ' .. tostring(e))
end)
