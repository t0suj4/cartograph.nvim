-- mixproj: mix's lowered program as facts, its binding-time sets derived by rules (CART-1524). The sets are read off
-- mix's own lowering (prog.freshroot), so these pin what mix CONSUMES, each exclusion beside a variable that keeps it.

local MX = require 'cartograph.mix'
local R = require 'cartograph.algebraread'
local A = require('cartograph.algebra').load()
local P = require 'cartograph.mixproj'

local function ready() if not pcall(vim.treesitter.get_string_parser, '', 'lua') then skip 'no lua parser' end end
local function names(prog, set)
    local out = {}
    for id in pairs(set or {}) do out[#out + 1] = tostring(prog.names[id]) end
    table.sort(out)
    return out
end

local SRC = [[
local function f(p, q)
    local s = {}
    s.a = 1
    local u = {}
    u = q
    local w = {}
    table.insert(w, 1)
    local c = {}
    local g = function () c.x = 1 end
    g()
    p.k = 1
    return s, u, w, c
end
]]

test('mixproj: the FRESH ROOTS mix lowers with — a constructed local stored into stays fresh; reassigned, mutated, closure-stored and parameter locals do not', function ()
    ready()
    local prog = MX.lower(assert(R.read(SRC, 'lua')))
    eq({ 's' }, names(prog, prog.freshroot), 'only s')
    -- (each exclusion has its own cause: the forced set says why w, c and p are out; u is out by reassignment)
    local forced = names(prog, prog.forced)
    for _, n in ipairs({ 'w', 'c', 'p' }) do ok(vim.tbl_contains(forced, n), n .. ' is forced: ' .. table.concat(forced, ' ')) end
    eq(false, vim.tbl_contains(forced, 'u'), 'u is not forced — reassignment alone excludes it')
end)

test('mixproj: the rules see the facts — the same program without the reassignment makes u fresh', function ()
    ready()
    local prog = MX.lower(assert(R.read((SRC:gsub('    u = q\n', '')), 'lua')))
    eq({ 's', 'u' }, names(prog, prog.freshroot))
end)

test('mixproj: the projection is a SET in canonical order — two runs, the same facts', function ()
    ready()
    local prog = MX.lower(assert(R.read(SRC, 'lua')))
    local function shown() local o = {}; for _, f in ipairs(P.facts(prog.funcs, { mutates = { ['table.insert'] = true } })) do o[#o + 1] = A.show(f) end; table.sort(o); return o end
    local a, b = shown(), shown()
    eq(a, b)
    ok(#a > 10, #a .. ' facts')
    ok(vim.tbl_contains(a, '(mutate ' .. A.show(A.lit(next(prog.forced) and (function () for id, n in pairs(prog.names) do if n == 'w' then return id end end end)())) .. ')'),
        'the mutate fact names w')
end)
