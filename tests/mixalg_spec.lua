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

test('mixalg: a closure mix cannot lower is REFUSED by name, never a Lua error — transplant crashed lowering on an empty block before CART-1335', function ()
    ready()
    local text = MA.program('M.transplant')
    local got = {}
    local okl, e = pcall(require('cartograph.mix').lower, assert(R.read(text, 'lua')), { collect = got })
    ok(okl or (type(e) == 'table' and e.refusal ~= nil), 'a refusal or a lowering, not ' .. tostring(e))
end)
