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

test('mix: what mix does not handle is REFUSED by name — while, varargs, method calls, a static value that never repeats', function ()
    ready()
    local function refusal(src, fname, division, statics)
        local okm, e = pcall(MX.mix, assert(R.read(src, 'lua')), fname, division, statics)
        eq(false, okm)
        return type(e) == 'table' and e.refusal or ('NOT A REFUSAL: ' .. tostring(e))
    end
    ok(refusal('local function f(x)\n    while x > 0 do x = x - 1 end\n    return x\nend\n', 'f', { 'D' }, {}):find('while', 1, true))
    ok(refusal('local function f(...)\n    return 1\nend\n', 'f', {}, {}):find('parameter', 1, true))
    ok(refusal('local function f(s)\n    return s:upper()\nend\n', 'f', { 'D' }, {}):find('method call', 1, true))
    ok(refusal('local function f(x, n)\n    if x > 0 then return f(x - 1, n + 1) end\n    return n\nend\n', 'f', { 'D', 'S' }, { nil, 0 }):find('specialization depth', 1, true))
end)

-- ── RUNG 2: closures and continuation-passing style ───────────────────────────────────────────────────────────────
-- a regular-expression matcher in CONTINUATION-PASSING style over a STATIC regex tree: `seq` and `star` BUILD a
-- continuation per step, capturing the current position — the shape of the algebra's own matcher (S1)
local REGEX = [[
local function mt(re, s, j, k)
    local op = re[1]
    if op == "chr" then
        if j <= #s and string.sub(s, j, j) == re[2] then return k(j + 1) end
        return false
    end
    if op == "seq" then
        return mt(re[2], s, j, function (j2) return mt(re[3], s, j2, k) end)
    end
    if op == "alt" then
        if mt(re[2], s, j, k) then return true end
        return mt(re[3], s, j, k)
    end
    if op == "star" then
        if k(j) then return true end
        return mt(re[2], s, j, function (j2)
            if j2 == j then return false end
            return mt(re, s, j2, k)
        end)
    end
    return false
end
local function rmatch(re, s, j0)
    return mt(re, s, j0, function (j) return j == #s + 1 end)
end
local function rmatchk(re, s, j0, k)
    return mt(re, s, j0, k)
end
]]
local function chr(c) return { 'chr', c } end
local function seq(a, b) return { 'seq', a, b } end
local REGEXES = {
    ['ab'] = seq(chr('a'), chr('b')),
    ['ab|a'] = { 'alt', seq(chr('a'), chr('b')), chr('a') },
    ['a*'] = { 'star', chr('a') },
    ['(a|b)*b'] = seq({ 'star', { 'alt', chr('a'), chr('b') } }, chr('b')),
    ['a(ba)*'] = seq(chr('a'), { 'star', seq(chr('b'), chr('a')) }),
}
-- every string over {a, b} up to length 5
local function strings()
    local out, layer = { '' }, { '' }
    for _ = 1, 5 do
        local nxt = {}
        for _, w in ipairs(layer) do nxt[#nxt + 1] = w .. 'a'; nxt[#nxt + 1] = w .. 'b' end
        for _, w in ipairs(nxt) do out[#out + 1] = w end
        layer = nxt
    end
    return out
end

test('mix: a CPS matcher specialized to its regex — continuations built PER STEP are specialized away; equivalent on every string; fewer steps', function ()
    ready()
    local rm = original(REGEX, 'rmatch')
    local words = strings()
    for name, re in pairs(REGEXES) do
        local r, text, _, T, T2 = residual(REGEX, 'rmatch', { 'S', 'D', 'D' }, { re })
        local hits = 0
        for _, w in ipairs(words) do
            local want = rm(re, w, 1)
            eq(want, r(w, 1), ('%s on %q'):format(name, w))
            if want then hits = hits + 1 end
        end
        ok(hits > 0 and hits < #words, name .. ': the strings both match and miss')
        gone(text, { 're', 'k', 'op' })
        ok(not text:find('function %('), name .. ': no residual closure — every continuation unfolded or a program point\n' .. text)
        local s0, s1 = 0, 0
        local entry = text:match('return ([%w_]+)%s*$')
        for _, w in ipairs({ 'ab', 'aba', 'bbab', 'aaaa' }) do
            local _, a = MX.run(MX.lower(T), 'rmatch', { re, w, 1 })
            local _, b = MX.run(MX.lower(T2), entry, { w, 1 })
            s0, s1 = s0 + a, s1 + b
        end
        -- (1.91x .. 2.24x over the five when written: every continuation call and every regex dispatch gone)
        ok(s1 * 3 < s0 * 2, ('%s PAYOFF: %d interpreter steps -> %d'):format(name, s0, s1))
    end
end)

test('mix: a DYNAMIC continuation stays a residual call; closures built around it still carry the position in', function ()
    ready()
    local rk = original(REGEX, 'rmatchk')
    local words = strings()
    for _, name in ipairs({ 'ab', '(a|b)*b', 'a(ba)*' }) do
        local re = REGEXES[name]
        local r, text = residual(REGEX, 'rmatchk', { 'S', 'D', 'D', 'D' }, { re })
        ok(text:find('k_%d+%('), name .. ': the dynamic continuation is called in the residual\n' .. text)
        for _, w in ipairs(words) do
            local ends = function (j) return j == #w + 1 end
            local any = function (j) return j > 2 end
            eq(rk(re, w, 1, ends), r(w, 1, ends), ('%s on %q (ends)'):format(name, w))
            eq(rk(re, w, 1, any), r(w, 1, any), ('%s on %q (any)'):format(name, w))
        end
        gone(text, { 're', 'op' })
    end
end)

local LIFT = [[
local function wrap(n, g, x)
    return g(function (y) return y + n end, x)
end
local function wrap2(n, g, x)
    return g(function (y) return y * n + x end, x)
end
]]

test('mix: a closure reaching a DYNAMIC call is LIFTED — a residual function, its static free variables computed, its dynamic ones in scope', function ()
    ready()
    local w1, w2 = original(LIFT, 'wrap'), original(LIFT, 'wrap2')
    local gs = { function (f, x) return f(x) * 2 end, function (f, x) return f(f(x)) end, function (_, x) return x end }
    for _, n in ipairs({ 0, 5 }) do
        local r1, t1 = residual(LIFT, 'wrap', { 'S', 'D', 'D' }, { n })
        local r2, t2 = residual(LIFT, 'wrap2', { 'S', 'D', 'D' }, { n })
        for _, g in ipairs(gs) do
            for _, x in ipairs({ -2, 0, 3 }) do
                eq(w1(n, g, x), r1(g, x), ('wrap(%d, g, %d)'):format(n, x))
                eq(w2(n, g, x), r2(g, x), ('wrap2(%d, g, %d)'):format(n, x))
            end
        end
        ok(t1:find('function %(y_%d+%)') and t2:find('function %(y_%d+%)'), 'a residual function expression\n' .. t1 .. t2)
        gone(t1, { 'n' }); gone(t2, { 'n' })
        ok(t2:find('x_%d+%)'), 'the dynamic free x is referenced inside the lifted function\n' .. t2)
    end
end)

local EARLY = [[
local function twice(f)
    return f(f(1))
end
local function addx(x)
    return twice(function (y) return y + x end)
end
local function mk(x)
    return function () return x end
end
local function use(g)
    local f = mk(g())
    return f() + f()
end
]]

test('mix: a closure\'s DYNAMIC parts are never computed early — a call whose only non-static argument is a closure is specialized, not run; an argument with an effect is not copied into a closure body', function ()
    ready()
    local addx, use = original(EARLY, 'addx'), original(EARLY, 'use')
    local r1, t1 = residual(EARLY, 'addx', { 'D' }, {})
    for _, x in ipairs({ -3, 0, 7 }) do eq(addx(x), r1(x), 'addx(' .. x .. ')') end
    ok(not t1:find('function %('), 'the closure applied twice is unfolded, never run with x unknown\n' .. t1)
    local r2, t2 = residual(EARLY, 'use', { 'D' }, {})
    local function counter() local n = 0; return function () n = n + 1; return n * 10 end end
    eq(use(counter()), r2(counter()), 'g runs ONCE, as in the original — not once per call of the closure\n' .. t2)
end)

test('mix: what rung 2 does not handle is REFUSED by name — a captured per-iteration local, a closure assigning or storing into a captured variable', function ()
    ready()
    local function refusal(src, fname, division, statics)
        local okm, e = pcall(MX.mix, assert(R.read(src, 'lua')), fname, division, statics)
        eq(false, okm)
        return type(e) == 'table' and e.refusal or ('NOT A REFUSAL: ' .. tostring(e))
    end
    local r1 = refusal('local function f(t)\n    local out = {}\n    for i = 1, 3 do out[i] = function () return i end end\n    return out\nend\n', 'f', { 'D' }, {})
    ok(r1:find('a local of one loop iteration', 1, true), r1)
    local r2 = refusal('local function f(x)\n    local n = 0\n    local g = function () n = n + 1 end\n    g()\n    return n\nend\n', 'f', { 'D' }, {})
    ok(r2:find('assigning the captured `n`', 1, true), r2)
    local r3 = refusal('local function f(x)\n    local t = {}\n    local g = function () t[1] = x end\n    g()\n    return t[1]\nend\n', 'f', { 'D' }, {})
    ok(r3:find('assigning the captured `t`', 1, true), r3)
end)

test('mix: the CENSUS — lower with { collect = {} } records every refused statement and goes on, so one run lists what blocks mix on a program', function ()
    ready()
    local got = {}
    local prog = MX.lower(assert(R.read('local function f(x)\n    local a, b = g(x)\n    if x then return x:upper() end\n    return a\nend\nlocal function g(y)\n    while y do y = false end\n    return y\nend\n', 'lua')), { collect = got })
    eq({ 'a declaration with 2 names and 1 values (rung 1: one each)', 'a method call `x:upper` (rung 2)', '`while_statement` (not in S)' },
        vim.tbl_map(function (r) return r.why end, got))
    ok(prog.funcs.f and prog.funcs.g, 'both functions lowered, the refused statements skipped')
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
