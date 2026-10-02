-- cartograph.mix — the offline partial evaluator for the Lua subset S (CART-1278, S2 of CART-1276). THE GATE, three
-- checks, because the first alone passes a mix that specializes nothing:
--   EQUIVALENCE    mix(f, s)(d) == f(s, d) over several s, with d hitting both arms of every dynamic `if`
--   ANTI-TRIVIAL   no static parameter survives in the residual (an all-D binding-time analysis is sound and passes
--                  equivalence; this is what catches it)
--   PAYOFF         a small interpreter specialized to its program (the first projection in miniature) takes FEWER steps
-- plus every unsupported construct REFUSED by name, and mix itself staying inside S (S4–S5 self-apply it).
local MX = require 'cartograph.mix'
local R = require 'cartograph.algebraread'
local A = require('cartograph.algebra').load()

local function ready() if not pcall(vim.treesitter.get_string_parser, '', 'lua') then skip 'no lua parser' end end
local function original(src, fname) return assert(load(src .. '\nreturn ' .. fname))() end
local function residual(src, fname, division, statics)
    local T = assert(R.read(src, 'lua'))
    local text, stats = MX.mix(T, fname, division, statics)
    local T2 = assert(R.read(text, 'lua'))
    eq(text, A.cst_print(T2), 'the residual round-trips through algebraread')
    return assert(load(text))(), text, stats, T, T2
end
local function idents(text)
    local root = vim.treesitter.get_string_parser(text, 'lua'):parse()[1]:root()
    local q = vim.treesitter.query.parse('lua', '(identifier) @i')
    local out = {}
    for _, n in q:iter_captures(root, text, 0, -1) do out[vim.treesitter.get_node_text(n, text)] = true end
    return out
end
-- none of `names` survives as a residual variable (residual names are <source name>_<id>)
local function gone(text, names)
    for id in pairs(idents(text)) do
        for _, n in ipairs(names) do ok(not id:match('^' .. n .. '_%d+$'), ('static `%s` survives as %s\n%s'):format(n, id, text)) end
    end
end

local POWER = [[
local function power(x, n)
    if n == 0 then return 1 end
    return x * power(x, n - 1)
end
]]

local MACHINE = [[
local function run(prog, pc, acc, x)
    if pc > #prog then return acc end
    local ins = prog[pc]
    local op = ins[1]
    if op == "add" then return run(prog, pc + 1, acc + ins[2], x) end
    if op == "addx" then return run(prog, pc + 1, acc + x, x) end
    if op == "mulx" then return run(prog, pc + 1, acc * x, x) end
    if op == "jnz" then
        if acc ~= 0 then return run(prog, ins[2], acc - 1, x) end
        return run(prog, pc + 1, acc, x)
    end
    return acc
end
]]

test('mix: power specialized to n — equivalent for every x, n gone, one expression', function ()
    ready()
    local f = original(POWER, 'power')
    for n = 0, 5 do
        local r, text = residual(POWER, 'power', { 'D', 'S' }, { nil, n })
        for _, x in ipairs({ 2, 3, -1.5, 0 }) do eq(f(x, n), r(x), ('power(%s, %d)'):format(x, n)) end
        gone(text, { 'n' })
    end
    local _, text = residual(POWER, 'power', { 'D', 'S' }, { nil, 3 })
    ok(text:find('return (x_1 * (x_1 * (x_1 * 1)))', 1, true), 'unfolded to one expression\n' .. text)
end)

test('mix: an interpreter specialized to its PROGRAM is that program compiled (the first projection, in miniature)', function ()
    ready()
    local run = original(MACHINE, 'run')
    local programs = {
        { { 'add', 3 }, { 'mulx' }, { 'add', 1 } },
        { { 'addx' }, { 'mulx' }, { 'mulx' } },
        { { 'add', 2 }, { 'addx' }, { 'mulx' }, { 'add', -4 } },
    }
    for i, prog in ipairs(programs) do
        local r, text, _, T, T2 = residual(MACHINE, 'run', { 'S', 'S', 'S', 'D' }, { prog, 1, 0 })
        for _, x in ipairs({ 0, 1, 2, 5, -3 }) do eq(run(prog, 1, 0, x), r(x), ('program %d, x = %d'):format(i, x)) end
        gone(text, { 'prog', 'pc', 'ins', 'op' })
        local _, s0 = MX.run(MX.lower(T), 'run', { prog, 1, 0, 2 })
        local _, s1 = MX.run(MX.lower(T2), text:match('return ([%w_]+)%s*$'), { 2 })
        ok(s1 * 4 < s0, ('PAYOFF: %d interpreter steps -> %d'):format(s0, s1))
    end
end)

test('mix: a LOOP in the interpreted program under DYNAMIC control becomes a residual recursive function', function ()
    ready()
    local run = original(MACHINE, 'run')
    local prog = { { 'addx' }, { 'jnz', 2 }, { 'add', 7 } }
    local r, text, stats = residual(MACHINE, 'run', { 'S', 'S', 'S', 'D' }, { prog, 1, 0 })
    for _, x in ipairs({ 0, 1, 3, 10 }) do eq(run(prog, 1, 0, x), r(x), 'x = ' .. x) end
    eq(2, stats.functions, 'the entry and ONE program point for the loop (pc = 2), memoized, not unrolled')
    gone(text, { 'prog', 'pc' })
end)

local CONGRUENCE = [[
local function f(n, d)
    local k = n * 2
    local acc = 0
    if d > 0 then
        acc = k + d
    else
        acc = k - d
    end
    for i = 1, n do acc = acc + i end
    for i = 1, d do acc = acc + k end
    local t = { n, d, k }
    local s = 0
    for _, v in ipairs({ 1, 2, n }) do s = s + v * d end
    local seen = 0
    if d > 0 then seen = n end
    return acc + t[2] + s + seen
end
]]

test('mix: CONGRUENCE — a variable assigned under dynamic control stays dynamic; static loops unroll, a dynamic one stays', function ()
    ready()
    local f = original(CONGRUENCE, 'f')
    for _, n in ipairs({ 0, 1, 3 }) do
        local r, text = residual(CONGRUENCE, 'f', { 'S', 'D' }, { n })
        for _, d in ipairs({ -1, 0, 2, 4 }) do eq(f(n, d), r(d), ('f(%d, %d)'):format(n, d)) end
        gone(text, { 'n', 'k' })
        ok(text:find('acc_%d+ = '), 'acc is assigned under `if d > 0`: residual')
        ok(text:find('seen_%d+ = ' .. n), 'seen gets a STATIC value under dynamic control: residual all the same (the congruence)')
        ok(text:find('for i_%d+ = 1, d_%d+, 1 do'), 'the loop bounded by d stays a loop')
    end
end)

test('mix: what rung 1 does not handle is REFUSED by name — closures, while, varargs, method calls, a static value that never repeats', function ()
    ready()
    local function refusal(src, fname, division, statics)
        local okm, e = pcall(MX.mix, assert(R.read(src, 'lua')), fname, division, statics)
        eq(false, okm)
        return type(e) == 'table' and e.refusal or ('NOT A REFUSAL: ' .. tostring(e))
    end
    ok(refusal('local function f(x)\n    local g = function (y) return y end\n    return g(x)\nend\n', 'f', { 'D' }, {}):find('closures', 1, true))
    ok(refusal('local function f(x)\n    while x > 0 do x = x - 1 end\n    return x\nend\n', 'f', { 'D' }, {}):find('while', 1, true))
    ok(refusal('local function f(...)\n    return 1\nend\n', 'f', {}, {}):find('parameter', 1, true))
    ok(refusal('local function f(s)\n    return s:upper()\nend\n', 'f', { 'D' }, {}):find('method call', 1, true))
    ok(refusal('local function f(x, n)\n    if x > 0 then return f(x - 1, n + 1) end\n    return n\nend\n', 'f', { 'D', 'S' }, { nil, 0 }):find('specialization depth', 1, true))
end)

test('mix: mix itself stays INSIDE S — no while / repeat / goto / varargs / metatables / load (S4–S5 self-apply it)', function ()
    ready()
    local path = vim.api.nvim_get_runtime_file('lua/cartograph/mix.lua', false)[1]
    local src = io.open(path):read('a')
    local root = vim.treesitter.get_string_parser(src, 'lua'):parse()[1]:root()
    local bad = {}
    local BADNODE = { while_statement = true, repeat_statement = true, goto_statement = true, label_statement = true, vararg_expression = true }
    local BADCALL = { setmetatable = true, getmetatable = true, load = true, loadstring = true, dofile = true, rawget = true, rawset = true, setfenv = true }
    local function walk(n)
        if BADNODE[n:type()] then bad[#bad + 1] = n:type() .. ' at line ' .. (n:start() + 1) end
        if n:type() == 'function_call' then
            local callee = vim.treesitter.get_node_text(n:named_child(0), src)
            if BADCALL[callee] or callee:match('^coroutine%.') or callee:match('^debug%.') then bad[#bad + 1] = callee .. ' at line ' .. (n:start() + 1) end
        end
        for c in n:iter_children() do if c:named() then walk(c) end end
    end
    walk(root)
    eq({}, bad)
end)
