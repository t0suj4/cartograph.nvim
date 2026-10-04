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

test('mixalg: a configuration whose KEY cannot be formed refuses FAST — the fallback program point would meet the same key (CART-1455)', function ()
    ready()
    -- (`local ?1 = 1 return ?1`: match's continuation chain nests past 20 — CART-1456. Under the budget given here the
    -- old behaviour, rollback and retry, ran out of BUDGET instead of naming the key)
    local rules_ = assert(require('cartograph.byexample').learn('local function f()\n  local a = 1\n  return a\nend', 'local function f()\n  local a = 1\n  a = a + 1\n  return a\nend', 'lua'))
    local okc, e = pcall(MA.compile_match, rules_[1].lhs, { budget = 2e5 })
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

test('mixalg: a closure mix cannot lower is REFUSED by name, never a Lua error — transplant crashed lowering on an empty block before CART-1335', function ()
    ready()
    local text = MA.program('M.transplant')
    local got = {}
    local okl, e = pcall(require('cartograph.mix').lower, assert(R.read(text, 'lua')), { collect = got })
    ok(okl or (type(e) == 'table' and e.refusal ~= nil), 'a refusal or a lowering, not ' .. tostring(e))
end)
