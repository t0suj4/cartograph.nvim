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
    local text, stats, pool = MX.mix(T, fname, division, statics)
    local T2 = assert(R.read(text, 'lua'))
    eq(text, A.cst_print(T2), 'the residual round-trips through algebraread')
    return assert(load(text, fname, 't', setmetatable({ MIXK = pool }, { __index = _G })))(), text, stats, T, T2
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

-- ── LOOPS (CART-1450 rung 1): while / repeat / break ─────────────────────────────────────────────────────────────
local LOOPS = [[
local function wpow(x, n)
    local r, i = 1, 0
    while i < n do r = r * x; i = i + 1 end
    return r
end
local function collatz(x)
    local c = 0
    while x > 1 do
        if x % 2 == 0 then x = x / 2 else x = 3 * x + 1 end
        c = c + 1
    end
    return c
end
local function find(t, x)
    local at = 0
    for i, v in ipairs(t) do
        if v == x then at = i; break end
    end
    return at
end
local function prefix(t, x)
    local s = 0
    for _, v in ipairs(t) do
        if v == x then break end
        s = s + v
    end
    return s
end
local function upto(t, x)
    local s = x
    for _, v in ipairs(t) do
        if v < 0 then break end
        s = s + v
    end
    return s
end
local function rep(x)
    local n = 0
    repeat
        local y = x - n
        n = n + 1
    until y <= 0
    return n
end
local function isqrt(x)
    local i = 0
    while true do
        i = i + 1
        if i * i > x then break end
    end
    return i
end
]]

test('mix: LOOPS — a static while unrolls, a dynamic while / repeat stays; equivalent, the static bound gone', function ()
    ready()
    local o = original(LOOPS, 'wpow')
    for _, n in ipairs({ 0, 1, 3 }) do
        local r, text = residual(LOOPS, 'wpow', { 'D', 'S' }, { nil, n })
        for _, x in ipairs({ -2, 0, 5 }) do eq(o(x, n), r(x), ('wpow(%d, %d)'):format(x, n)) end
        gone(text, { 'n', 'i' })
        ok(not text:find('while', 1, true), 'a static condition unrolls\n' .. text)
    end
    for _, f in ipairs({ 'collatz', 'rep', 'isqrt' }) do
        local of = original(LOOPS, f)
        local r, text = residual(LOOPS, f, { 'D' }, {})
        for _, x in ipairs({ 0, 1, 3, 6, 7, 10 }) do eq(of(x), r(x), ('%s(%d)'):format(f, x)) end
        ok(text:find(f == 'rep' and 'until %(y_%d+ <= 0%)' or 'while ', 1), 'the dynamic loop stays a loop\n' .. text)
    end
end)

test('mix: LOOPS — a BREAK: a static one ends the unrolling, a dynamic one leaves `repeat … until true`, and makes every store of its loop dynamic', function ()
    ready()
    local T = { 5, 7, 9 }
    for _, f in ipairs({ 'find', 'prefix', 'upto' }) do
        local of = original(LOOPS, f)
        local tt = f == 'upto' and { 1, 2, -1, 5 } or T
        local r, text = residual(LOOPS, f, { 'S', 'D' }, { tt })
        for _, x in ipairs({ 4, 5, 7, 9, 10 }) do eq(of(tt, x), r(x), ('%s(%d)'):format(f, x)) end
        gone(text, { 't', 'v', 'i' })
        if f == 'upto' then
            -- (a STATIC break: the unrolling stops at -1, no wrapper, no break, the sum folded to x + 3)
            ok(not text:find('repeat', 1, true) and not text:find('break', 1, true), 'a static break leaves nothing\n' .. text)
        else
            ok(text:find('repeat', 1, true) and text:find('until true', 1, true), 'a dynamic break leaves a wrapper\n' .. text)
        end
    end
    -- (the CONGRUENCE of a break: `s = s + v` after a dynamic `if v == x then break end` — a static s would sum every
    -- element whatever x is)
    local _, text = residual(LOOPS, 'prefix', { 'S', 'D' }, { T })
    ok(text:find('s_%d+ = '), 'the sum is residual\n' .. text)
end)

test('mix: a constructor\'s LAST POSITIONAL field EXPANDS a call\'s values — `{ unpack(t) }` copies the whole list, statically and at run time (CART-1461)', function ()
    ready()
    local src = [[
local function two() return 7, 8 end
local function child(path, i)
    local p = { unpack(path) }
    p[#p + 1] = i
    return p
end
local function f(path, d)
    local a = child(path, #d)
    local b = { 0, unpack(path) }
    local c = { k = 1, two() }
    local e = { [2] = 5, two() }
    local g = { 1, 2, unpack(d) }
    local h = { k = 3, unpack(d) }
    return table.concat(a, '/') .. '|' .. table.concat(b, '/') .. '|' .. c[1] .. c[2] .. c.k .. '|' .. e[1] .. e[2] .. '|' .. table.concat(g, '/')
        .. '|' .. h.k .. table.concat(h, '/')
end
]]
    local o = original(src, 'f')
    -- (path static: the expansion is computed; d dynamic: the tables holding it are built at run time)
    local r, text = residual(src, 'f', { 'S', 'D' }, { { 1, 3, 5 } })
    for _, d in ipairs({ { 9 }, { 9, 10, 11 } }) do eq(o({ 1, 3, 5 }, d), r(d)) end
    -- (and both dynamic: the residual prints the expanding field positionally, or appends it past other keys)
    local r2, text2 = residual(src, 'f', { 'D', 'D' }, {})
    for _, p in ipairs({ { 1 }, { 1, 3, 5, 7 } }) do eq(o(p, { 4 }), r2(p, { 4 })) end
    ok(text2:find('{ unpack(path_', 1, true), 'positional: `{ unpack(path) }`\n' .. text2)
    ok(text2:find('select("#", ...)', 1, true), 'past a named key: appended at run time\n' .. text2)
end)

test('mix: a NON-FINITE number reaching dynamic code is lifted as the division that makes it — 1/0, -1/0, 0/0', function ()
    ready()
    local src = 'local function f(x)\n    local best, worst = math.huge, -math.huge\n    if x < best then best = x end\n    if x > worst then worst = x end\n    return best, worst\nend\n'
    local r, text = residual(src, 'f', { 'D' }, {})
    for _, x in ipairs({ -3, 0, 7 }) do
        local b, w = r(x)
        local ob, ow = original(src, 'f')(x)
        eq(ob, b); eq(ow, w)
    end
    ok(text:find('(1 / 0)', 1, true) and text:find('(-1 / 0)', 1, true), text)
end)

test('mix: a refusal is LOCATED — lowering names the innermost statement\'s line, specialization adds the active calls (CART-1459)', function ()
    ready()
    local okl, e = pcall(MX.lower, assert(R.read('local function f(x)\n    if x then\n        goto done\n    end\n    ::done::\n    return x\nend\n', 'lua')))
    eq(false, okl)
    eq(3, e.at, 'the goto, line 3 — not its if')
    local got = {}
    MX.lower(assert(R.read('local function f(x)\n    goto e\n    ::e::\n    return x\nend\n', 'lua')), { collect = got })
    eq({ 2, 3 }, vim.tbl_map(function (r) return r.at end, got))
    -- (a specialization refusal: the static value that never repeats, located at its statement, with the calls)
    local src = 'local function g(x, k)\n    if x > 0 then return g(x - 1, function (y) return k(y) + 1 end) end\n    return k(x)\nend\nlocal function f(x)\n    return g(x, function (y) return y end)\nend\n'
    local oks, e2 = pcall(MX.mix, assert(R.read(src, 'lua')), 'f', { 'D' }, {})
    eq(false, oks)
    eq(2, e2.at)
    ok(#e2.chain > 3 and e2.chain[#e2.chain] == 'f', vim.inspect(e2.chain))
    ok(MX.describe(e2):find('at line 2, in g', 1, true), MX.describe(e2))
end)

test('mix: with a LINE MAP, an error the evaluator raises carries the ORIGINAL\'s position — `error(msg)` and a lazy error alike (CART-1458)', function ()
    ready()
    -- (line n of the text mix reads came from line 100 + n of orig.lua)
    local lines = {}
    for n = 1, 20 do lines[n] = { src = 'orig.lua', line = 100 + n } end
    local src = 'local function bad(x)\n    error("bad " .. x)\nend\nlocal function f(x, d)\n    local ok, why = pcall(bad, x)\n    return why .. d\nend\n'
    local text, _, pool = MX.mix(assert(R.read(src, 'lua')), 'f', { 'S', 'D' }, { 7 }, { lines = lines })
    local r = assert(load(text, 'f', 't', setmetatable({ MIXK = pool }, { __index = _G })))()
    eq('orig.lua:102: bad 7!', r('!'), 'the position of the error call in the ORIGINAL, not mix.lua\'s\n' .. text)
    -- (a lazy error: a static computation that raises, in an arm only a dynamic guard reaches)
    local src2 = 'local function f(t, d)\n    if d then\n        return t.kids[1].k\n    end\n    return 0\nend\n'
    local text2, _, pool2 = MX.mix(assert(R.read(src2, 'lua')), 'f', { 'S', 'D' }, { { kids = {} } }, { lines = lines })
    local r2 = assert(load(text2, 'f', 't', setmetatable({ MIXK = pool2 }, { __index = _G })))()
    eq(0, r2(false))
    local okr, err = pcall(r2, true)
    eq(false, okr)
    ok(tostring(err):find('^orig%.lua:103: '), tostring(err))
end)

test('mix: a COMMENT is trivia anywhere — between a table\'s fields, a call\'s arguments', function ()
    ready()
    local src = 'local function f(x)\n    local t = {\n        -- one\n        x,\n        -- two\n        x + 1,\n    }\n    return math.max(\n        -- a\n        t[1], t[2]\n    )\nend\n'
    local r = residual(src, 'f', { 'D' }, {})
    eq(original(src, 'f')(3), r(3))
end)

test('mix: what mix does not handle is REFUSED by name — goto, varargs, a static value that never repeats and generalizing cannot fix', function ()
    ready()
    local function refusal(src, fname, division, statics)
        local okm, e = pcall(MX.mix, assert(R.read(src, 'lua')), fname, division, statics)
        eq(false, okm)
        return type(e) == 'table' and e.refusal or ('NOT A REFUSAL: ' .. tostring(e))
    end
    ok(refusal('local function f(x)\n    goto done\n    ::done::\n    return x\nend\n', 'f', { 'D' }, {}):find('goto', 1, true))
    -- (a while whose static condition never turns false: the budget, by name)
    ok(refusal('local function f(x)\n    local i = 0\n    while i >= 0 do i = i + 1 end\n    return x\nend\n', 'f', { 'D' }, {}):find('budget', 1, true))
    ok(refusal('local function f(...)\n    return 1\nend\n', 'f', {}, {}):find('parameter', 1, true))
    -- (a continuation that grows by a closure per call: the join's hole falls on a closure argument — no generalization)
    ok(refusal('local function g(x, k)\n    if x > 0 then return g(x - 1, function (y) return k(y) + 1 end) end\n    return k(x)\nend\nlocal function f(x)\n    return g(x, function (y) return y end)\nend\n', 'f', { 'D' }, {}):find('specialization depth', 1, true))
end)

-- ── RUNG 4.0: GENERALIZATION — a configuration as an ALGEBRA TERM ─────────────────────────────────────────────────
test('mix: the WHISTLE is homeomorphic embedding over configuration terms — a number embeds a number, a call embeds what it grew from; pinned both ways', function ()
    local function cfg(...) return MX.config_term('f', { 'D', 'S' }, { nil, ... }, {}) end
    ok(MX.embeds(cfg(0), cfg(1)), 'numbers: one symbol')
    ok(MX.embeds(cfg('a'), cfg('ab')), 'strings: one symbol')
    ok(not MX.embeds(cfg(true), cfg(false)), 'a boolean only itself')
    ok(not MX.embeds(cfg(0), cfg('a')), 'a number is no string')
    ok(MX.embeds(cfg({ 1 }), cfg({ 1, 2 })), 'a table embeds in a table with more around it (coupling by subsequence)')
    ok(not MX.embeds(cfg({ 1, 2 }), cfg({ 1 })), 'never the bigger in the smaller')
    ok(MX.embeds(cfg({ x = true }), cfg({ a = { x = true }, b = 1 })), 'diving: inside a field of the bigger')
    ok(not MX.embeds(cfg({ x = true }), cfg({ x = false })), 'and a leaf that differs is no embedding')
    -- a CONFIGURATION IS A TEMPLATE (CART-1341): a dynamic argument is a hole, so filling it is staging — the config of
    -- f(D, 5) instantiated with 7 IS the config of f(7, 5); and a hole embeds only a hole
    local Tc = A.template(MX.config_term('f', { 'D', 'S' }, { nil, 5 }, {}))
    eq({ 'a1' }, vim.tbl_keys(Tc.holes))
    eq(MX.config_term('f', { 'S', 'S' }, { 7, 5 }, {}), A.instantiate(Tc, { a1 = A.lit(7) }).term)
    ok(not MX.embeds(cfg(0), MX.config_term('f', { 'S', 'S' }, { 3, 0 }, {})), 'a dynamic argument does not embed a static one')
    -- POLYNOMIAL (CART-1334): a closure chain k deep against k + 1 — each (a, b) node pair decided ONCE, charged once.
    -- Unmemoized, diving and coupling reach the same pair along every path: 2^k (k = 22 took 0.23 s, k = 120 never ends)
    local function chain(k)
        local t = { k = 'clo:0', kids = {} }
        for _ = 1, k do t = { k = 'clo:1', kids = { t } } end
        return { k = 'g', kids = { { k = 'hole', h = 'a1' }, t } }
    end
    local pairs_decided = 0
    local function charge()
        pairs_decided = pairs_decided + 1
        if pairs_decided > 124 * 125 then error('more pairs than |a|·|b|', 0) end
    end
    ok(MX.embeds(chain(120), chain(121), {}, charge), 'a chain embeds in a longer one')
    ok(pairs_decided > 120 and pairs_decided <= 124 * 125, pairs_decided .. ' pairs decided')
    pairs_decided = 0
    ok(not MX.embeds(chain(121), chain(120), {}, charge), 'never the longer in the shorter')
end)

local GROW = [[
local function count(x, n)
    if x > 0 then return count(x - 1, n + 1) end
    return n
end
local function walk(x, n, step)
    if x > 0 then return walk(x - 1, n + step, step) end
    return n
end
local function steps(x, n)
    local y = x - 1
    if x > 0 then return steps(y, n + 1) end
    return n
end
local function word(x, acc)
    if x > 0 then return word(x - 1, acc .. "a") end
    return acc
end
local function sum(t, i, x)
    if i > #t then return 0 end
    return t[i] * x + sum(t, i + 1, x)
end
]]

test('mix: a static value that never repeats is GENERALIZED — past the depth, A.join of the call with the one it grew from makes the changed argument dynamic; equivalent', function ()
    ready()
    local xs = { -1, 0, 1, 5, 50 }
    local c0, w0, a0 = original(GROW, 'count'), original(GROW, 'walk'), original(GROW, 'word')
    local c, ct = residual(GROW, 'count', { 'D', 'S' }, { nil, 0 })
    local w, wt = residual(GROW, 'walk', { 'D', 'S', 'S' }, { nil, 0, 7 })
    local a, at = residual(GROW, 'word', { 'D', 'S' }, { nil, '' })
    for _, x in ipairs(xs) do
        eq(c0(x, 0), c(x), 'count ' .. x)
        eq(w0(x, 0, 7), w(x), 'walk ' .. x)
        eq(a0(x, ''), a(x), 'word ' .. x)
    end
    ok(ct:find('function count_%d+%(x_%d+, n_%d+%)'), 'a recursive program point that takes n\n' .. ct)
    -- (only what CHANGED is generalized: step repeats, so it stays static and is folded in)
    ok(wt:find('function walk_%d+%(x_%d+, n_%d+%)'), 'walk generalizes n, not step\n' .. wt)
    ok(wt:find('+ 7)', 1, true) and not wt:find('step_'), 'the unchanged step is still a constant\n' .. wt)
    ok(at:find('function word_%d+%(x_%d+, acc_%d+%)'), 'a string accumulator generalizes too\n' .. at)
    -- (a body that is no single `return`: the chain that ran past the depth was PROGRAM POINTS, rolled back before the
    -- retry — none left without a body)
    local p0 = original(GROW, 'steps')
    local p, pt, pstats = residual(GROW, 'steps', { 'D', 'S' }, { nil, 0 })
    for _, x in ipairs(xs) do eq(p0(x, 0), p(x), 'steps ' .. x) end
    eq(2, pstats.functions, 'the entry and the generalized point\n' .. pt)
end)

-- ── RUNG 4a: PARTIALLY STATIC DATA — a local RECORD is its fields (SRA) ─────────────────────────────────────────────
local RECORD = [[
local function f(x, n)
    local r = { a = n, b = x, c = 0 }
    r.c = r.a * 2
    if x > 0 then r.b = r.b + r.c end
    return r.a + r.b + r.c
end
local function k(t)
    return t.a + t.b
end
local function g(x, n)
    local r = { a = n, b = x }
    return k(r)
end
local function h(x, n)
    local r = { a = n }
    local function get() return r.a + x end
    return get()
end
local function p(x, n)
    local r = { n, x }
    r[1] = r[1] + 1
    return r[1] * r[2]
end
]]

test('mix: a local RECORD that never escapes is its FIELDS (SRA, CART-1331 rung 4a) — a static field folds away, a dynamic one is a residual local, no table is built; an escaping record stays a table', function ()
    ready()
    local prog = MX.lower(assert(R.read(RECORD, 'lua')))
    eq(4, prog.sra.candidates, 'four records')
    eq(2, prog.sra.replaced, 'f and p are replaced; g passes its record, h captures it')
    local function same(fname)
        local o, r, text = original(RECORD, fname), residual(RECORD, fname, { 'D', 'S' }, { nil, 5 })
        for _, x in ipairs({ -1, 0, 3 }) do eq(o(x, 5), r(x), fname .. ' ' .. x) end
        return text
    end
    local tf = same('f')
    ok(not tf:find('{', 1, true) and not tf:find('[', 1, true), 'f: no table built, no field read\n' .. tf)
    ok(tf:find('10', 1, true), 'f: r.c = r.a * 2 folded to 10\n' .. tf)
    local tp = same('p')
    ok(not tp:find('{', 1, true), 'p: positional fields too\n' .. tp)
    ok(same('g'):find('{', 1, true), 'g: an escaping record stays a table')
    same('h')
end)

local FOLD = [[
local function count(x, n)
    if x > 0 then return count(x - 1, n + 1) end
    return n
end
local function pair(x, y)
    return count(x, 0) + count(4, y)
end
]]

test('mix: reuse of a GENERALIZED configuration — by default only after the depth (today\'s behaviour); with reuse = eager, any call whose configuration is an INSTANCE of a recorded generalization folds onto it at once', function ()
    ready()
    local T = assert(R.read(FOLD, 'lua'))
    local o = original(FOLD, 'pair')
    local function run(opts)
        local text, _, pool = MX.mix(T, 'pair', { 'D', 'D' }, {}, opts)
        return assert(load(text, 'pair', 't', setmetatable({ MIXK = pool }, { __index = _G })))(), text
    end
    local d, dt = run(nil)
    local e, et = run({ reuse = 'eager' })
    for _, x in ipairs({ -1, 0, 3, 40 }) do
        for _, y in ipairs({ 0, 5 }) do
            eq(o(x, y), d(x, y), ('default pair(%d, %d)'):format(x, y))
            eq(o(x, y), e(x, y), ('eager pair(%d, %d)'):format(x, y))
        end
    end
    -- count(x, 0) generalized n; count(4, y) is an instance of count(?x, ?n): by default it is specialized to its
    -- static 4 and unrolls; eager, it folds onto the generalized function
    ok(not dt:find('count_%d+%(4, '), 'default: count(4, y) unrolled, no call\n' .. dt)
    ok(et:find('count_%d+%(4, y_%d+%)'), 'eager: count(4, y) calls the generalized count\n' .. et)
end)

test('mix: generalizing fires ONLY past the depth — a bounded static recursion still unrolls; a deeper one becomes a loop over a dynamic index', function ()
    ready()
    local s0 = original(GROW, 'sum')
    local t60, t300 = {}, {}
    for i = 1, 60 do t60[i] = i % 7 end
    for i = 1, 300 do t300[i] = i % 5 end
    local s, st, stats = residual(GROW, 'sum', { 'S', 'S', 'D' }, { t60, 1 })
    eq(1, stats.functions, 'sixty static steps: unrolled, no program point\n' .. st)
    local d, dt = residual(GROW, 'sum', { 'S', 'S', 'D' }, { t300, 1 })
    ok(dt:find('function sum_%d+%(i_%d+, x_%d+%)'), 'three hundred: the index generalized\n' .. dt)
    for _, x in ipairs({ -2, 0, 3 }) do
        eq(s0(t60, 1, x), s(x), 'sum60 ' .. x)
        eq(s0(t300, 1, x), d(x), 'sum300 ' .. x)
    end
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

-- ── PINS (CART-1450): a closure capturing a local of one loop iteration copies it when it is made ─────────────────
local PINS = [[
local function mk(n)
    local fs = {}
    for i = 1, n do
        local k = i * 10
        fs[i] = function () return k + i end
    end
    return fs
end
local function late(x, n)
    local fs = mk(n)
    return fs[1]() + fs[n]() + x
end
local function apply(g, a) return g(a) end
local function pre(t, x)
    local s = 0
    for _, e in ipairs(t) do
        local v = e
        if v < 0 then v = 0 end
        s = s + (function () return v + x end)()
    end
    return s
end
local function each(t, x)
    local r = 0
    for i, v in ipairs(t) do
        local d = v + x
        r = r + apply(function (y) return y * d end, i)
    end
    return r
end
]]

test('mix: PINS — a closure made in a loop sees ITS iteration\'s locals, called after the loop (static) or inside it (dynamic); equivalent', function ()
    ready()
    local o = original(PINS, 'late')
    for _, n in ipairs({ 1, 3 }) do
        local r, text = residual(PINS, 'late', { 'D', 'S' }, { nil, n })
        for _, x in ipairs({ 0, 5 }) do eq(o(x, n), r(x), ('late(%d, %d)'):format(x, n)) end
        ok(text:find('return %(' .. (11 + 11 * n) .. ' %+ x_%d+%)'), 'fs[1]() + fs[n]() folds to 11 + 11n — a shared slot would give the LAST iteration\'s k and i twice (22n)\n' .. text)
    end
    local oe = original(PINS, 'each')
    local T = { 2, 4, 6 }
    local r, text = residual(PINS, 'each', { 'S', 'D' }, { T })
    for _, x in ipairs({ -1, 0, 3 }) do eq(oe(T, x), r(x), ('each(%d)'):format(x)) end
    gone(text, { 't', 'v', 'i' })
    -- (a pin ASSIGNED BEFORE the closure captures it — derive.lua's `if … then v = nil end` before an immediately
    -- called function — copies the assigned value: accepted)
    local op = original(PINS, 'pre')
    local T2 = { 3, -2, 5 }
    local rp = residual(PINS, 'pre', { 'S', 'D' }, { T2 })
    for _, x in ipairs({ 0, 4 }) do eq(op(T2, x), rp(x), ('pre(%d)'):format(x)) end
end)

test('mix: what rung 3 does not handle is REFUSED by name — a pin the loop body assigns, a dynamic pin used after its iteration, a closure assigning a captured PARAMETER', function ()
    ready()
    local function refusal(src, fname, division, statics)
        local okm, e = pcall(MX.mix, assert(R.read(src, 'lua')), fname, division, statics)
        eq(false, okm)
        return type(e) == 'table' and e.refusal or ('NOT A REFUSAL: ' .. tostring(e))
    end
    local r1 = refusal('local function f(x)\n    local s = 0\n    for i = 1, 3 do\n        local k = i\n        local g = function () return k end\n        k = k + x\n        s = s + g()\n    end\n    return s\nend\n', 'f', { 'D' }, {})
    ok(r1:find('a local of one loop iteration that the loop body assigns', 1, true), r1)
    -- (the write comes AFTER its values: a closure in the right-hand side captures, then the variable changes)
    local r4 = refusal('local function f(x)\n    local s = 0\n    for i = 1, 3 do\n        local v = i\n        local g = nil\n        v, g = i * 2, function () return v end\n        s = s + g()\n    end\n    return s + x\nend\n', 'f', { 'D' }, {})
    ok(r4:find('that the loop body assigns', 1, true), r4)
    -- (an assignment written BEFORE the capture, but in a loop nested in the variable's scope: its next round runs after)
    local r5 = refusal('local function f(x)\n    local s = 0\n    for i = 1, 2 do\n        local v = i\n        local fs = {}\n        for j = 1, 2 do\n            v = v + 10\n            fs[j] = function () return v end\n        end\n        s = s + fs[1]()\n    end\n    return s + x\nend\n', 'f', { 'D' }, {})
    ok(r5:find('that the loop body assigns', 1, true), r5)
    local r3 = refusal('local function f(t, x)\n    local g = nil\n    for _, v in ipairs(t) do\n        local d = v + x\n        g = function () return d end\n    end\n    return g()\nend\n', 'f', { 'S', 'D' }, { { 1, 2 } })
    ok(r3:find('used after that iteration', 1, true), r3)
    local r2 = refusal('local function f(x)\n    local g = function () x = x + 1 end\n    g()\n    return x\nend\n', 'f', { 'D' }, {})
    ok(r2:find('assigning the captured parameter `x`', 1, true), r2)
end)

-- ── RUNG 3: several values, methods, boxes — what the algebra's own matcher needs (CART-1279's census) ─────────────
local RUNG3 = [[
local function check(v, lim)
    if v > lim then return false, ("%d exceeds %d"):format(v, lim) end
    return true, nil
end
local function count(xs, lim)
    local n = 0
    local seen = {}
    local function inc(x) n = n + 1; seen[#seen + 1] = x end
    for _, x in ipairs(xs) do
        local ok, why = check(x, lim)
        if ok then inc(x) end
    end
    local first, rest = 0, 0
    first, rest = n, #seen
    return first + rest, seen[1]
end
local function msg(v, lim)
    local ok, why = check(v, lim)
    if ok then return "ok" end
    return why:upper()
end
local function pair(n)
    return n, n * 2
end
local function twice(x, lim)
    local a, b = pair(lim)
    return x + a + b, pair(lim)
end
]]

test('mix: RUNG 3 — several values, method calls on strings, and a counter a closure assigns (a BOX) — equivalent, the static bound gone', function ()
    ready()
    local count, msg = original(RUNG3, 'count'), original(RUNG3, 'msg')
    for _, lim in ipairs({ 0, 2, 5 }) do
        local r1, t1 = residual(RUNG3, 'count', { 'D', 'S' }, { nil, lim })
        for _, xs in ipairs({ {}, { 1 }, { 3, 1, 6, 2 }, { 9, 9 } }) do
            local a1, b1 = count(xs, lim)
            local a2, b2 = r1(xs)
            eq({ a1, b1 }, { a2, b2 }, ('count(%s, %d)'):format(vim.inspect(xs, { newline = '' }), lim))
        end
        gone(t1, { 'lim' })
        ok(t1:find('n_%d+%[1%]'), 'n is a box: read and written through [1]\n' .. t1)
        local r2, t2 = residual(RUNG3, 'msg', { 'D', 'S' }, { nil, lim })
        for _, v in ipairs({ -1, lim, lim + 1, 40 }) do eq(msg(v, lim), r2(v), ('msg(%d, %d)'):format(v, lim)) end
        ok(t2:find('):upper()', 1, true) or t2:find('string.format', 1, true) or t2:find('):format(', 1, true), 'the method calls stay method calls\n' .. t2)
        -- (a STATIC call of several values: computed now, every value used — `local a, b = pair(lim)`, `return …, pair(lim)`)
        local twice = original(RUNG3, 'twice')
        local r3, t3 = residual(RUNG3, 'twice', { 'D', 'S' }, { nil, lim })
        for _, x in ipairs({ 0, 7 }) do eq({ twice(x, lim) }, { r3(x) }, ('twice(%d, %d): all three values'):format(x, lim)) end
        gone(t3, { 'lim', 'a', 'b' })
    end
end)

test('mix: a string literal\'s ESCAPES are read as Lua reads them — \\n \\t \\\\ \\" \\ddd \\xXX — and survive the residual', function ()
    ready()
    local src = 'local function f(x)\n    return x .. "a\\tb\\n\\065\\x42|\\\\|\\"" .. \'\\\'\'\nend\n'
    local r, text = residual(src, 'f', { 'D' }, {})
    eq(original(src, 'f')('>'), r('>'), text)
    eq('>a\tb\nAB|\\|"\'', r('>'))
end)

-- ── what specializing the algebra's REAL matcher needed (CART-1279) ───────────────────────────────────────────────────
local REAL = [[
local function lazyerr(t, x)
    if x then return t.kids[1] end
    return 0
end
local function gen(x, n)
    n = n or #x
    return n + 1
end
local function callgen(x)
    return gen(x)
end
local function pooled(t, i)
    return t[i]
end
local function deep(x)
    local list = { sites = {} }
    list.sites[#list.sites + 1] = x
    return list.sites[1]
end
local function short(env, x)
    return env.d and env.d[x] or 0
end
local function viaglobal(x)
    return G.twice(x)
end
local function id(x)
    return x
end
local function asvalue(x)
    local f = id
    return f(x) + 1
end
]]
-- a residual loaded with its constant pool (and G) in its environment
local function residual_env(fname, division, statics, opts, G)
    local T = assert(R.read(REAL, 'lua'))
    local text, _, pool = MX.mix(T, fname, division, statics, opts)
    local env = setmetatable({ MIXK = pool, G = G }, { __index = _G })
    return assert(load(text, fname, 't', env))(), text, pool
end

test('mix: what the REAL matcher needed — a lazy error, a generalized parameter, the constant pool, a deep store, a static short circuit, a known global, a function as a value', function ()
    ready()
    -- LAZY ERROR: `t.kids[1]` of a node with no kids, under a dynamic guard — raised only if the arm runs
    local f1, t1 = residual_env('lazyerr', { 'S', 'D' }, { {} })
    eq(0, f1(false))
    ok(not pcall(f1, true), 'the arm raises, as the original does')
    ok(t1:find('error(', 1, true), 'a residual error where the static computation failed\n' .. t1)
    -- GENERALIZE: n static (absent) at the call, dynamic in the body
    local f2, t2 = residual_env('callgen', { 'D' }, {})
    eq(4, f2({ 1, 2, 3 }))
    ok(t2:find('local n_%d+ = nil'), 'the generalized parameter starts as a local\n' .. t2)
    -- CONSTANT POOL: a static table read at a dynamic index — referenced, not copied
    local tbl = { 'a', 'b', 'c' }
    local f3, t3, pool = residual_env('pooled', { 'S', 'D' }, { tbl })
    eq({ 'a', 'c' }, { f3(1), f3(3) })
    ok(pool[1] == tbl and t3:find('MIXK[1]', 1, true), 'the SAME table, by reference\n' .. t3)
    -- DEEP STORE: `list.sites[n] = x` makes list dynamic
    local f4 = residual_env('deep', { 'D' }, {})
    eq('x', f4('x'))
    -- SHORT CIRCUIT: `env.d and …` with env.d static nil is 0, never `nil[x]`
    local f5, t5 = residual_env('short', { 'S', 'D' }, { {} })
    eq(0, f5('k'))
    ok(not t5:find('[', 1, true), 'the dead `env.d[x]` is gone, not merely parenthesized\n' .. t5)
    -- KNOWN GLOBAL: a host function reached by its PATH
    local G = { twice = function (x) return 2 * x end }
    local f6, t6 = residual_env('viaglobal', { 'D' }, {}, { globals = { ['G.twice'] = G.twice } }, G)
    eq(14, f6(7))
    ok(t6:find('G.twice(', 1, true), t6)
    -- A FUNCTION AS A VALUE: `local f = id` then `f(x)`
    local f7 = residual_env('asvalue', { 'D' }, {})
    eq(42, f7(41))
end)

test('mix: an UNFOLD attempt is a transaction — a program point it made, then failed, is rolled back, never reused bodiless', function ()
    ready()
    -- (g unfolds to inner(x); inner's body REFUSES — a dynamic pair expanding into h's parameters. The attempt to
    -- unfold g fails after point(inner) was registered; without the rollback the fallback reuses that bodiless point)
    local src = 'local function h(a, b, c)\n    return a\nend\nlocal function f(x)\n    return x, x\nend\nlocal function inner(x)\n    return h(x, f(x))\nend\nlocal function g(x)\n    return inner(x)\nend\nlocal function top(x)\n    return g(x)\nend\n'
    local okm, e = pcall(MX.mix, assert(R.read(src, 'lua')), 'top', { 'D' }, {})
    eq(false, okm)
    ok(type(e) == 'table' and e.refusal and e.refusal:find('expands several dynamic values', 1, true), 'refused by name, not a broken residual: ' .. vim.inspect(e))
end)

local EMPTY = [[
local function e1(a, b)
    local x = 0
    if a > 0 then elseif b > 0 then x = 1 end
    return x
end
local function e2(a, b)
    local x = 0
    if a > 0 then x = 2 elseif b > 0 then end
    return x
end
local function e3(a, b)
    local x = 0
    if a > 0 then else end
    return x + b
end
local function e4(a, b)
    local x = 0
    if a > 0 then elseif b > 0 then else x = 3 end
    return x
end
local function e5(a, b)
    local x = 0
    if a > 0 then end
    for i = 1, b do end
    do end
    return x + a
end
]]

test('mix: an EMPTY block is no node — `if a then elseif b then … end` puts the clause where the then-block would be; every block is taken by KIND (CART-1335), and each shape specializes equivalently', function ()
    ready()
    for _, f in ipairs({ 'e1', 'e2', 'e3', 'e4', 'e5' }) do
        local o = original(EMPTY, f)
        local r = residual(EMPTY, f, { 'D', 'D' }, {})
        for _, a in ipairs({ -1, 0, 2 }) do
            for _, b in ipairs({ -1, 0, 3 }) do eq(o(a, b), r(a, b), ('%s(%d, %d)'):format(f, a, b)) end
        end
    end
end)

test('mix: the CENSUS — lower with { collect = {} } records every refused statement and goes on, so one run lists what blocks mix on a program', function ()
    ready()
    local got = {}
    local prog = MX.lower(assert(R.read('local function f(x)\n    local h = function () x = 1 end\n    if x then return x:upper() end\n    return h\nend\nlocal function g(y)\n    goto e\n    ::e::\n    return y\nend\n', 'lua')), { collect = got })
    eq({ 'a closure assigning the captured parameter `x` (rung 3: a parameter is not boxed)', '`goto_statement` (not in S)', '`label_statement` (not in S)' },
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
