-- cartograph.mix — the GAPS a mutation campaign over mix.lua found (CART-1506): each test below is one CLUSTER of
-- surviving mutants, reduced to one program whose expected value is an ORACLE (the original Lua program's result, an
-- exact refusal phrase, an exact count) — never the residual compared with itself.
--
-- Sections, one per triage group (A lowering, B evaluator + BTA, C specializer, D printer + the rest), then the FILED
-- BUGS the triage found in the original code. A bug's test states the CORRECT behaviour; while the ticket is open it
-- fails with the documented symptom and SKIPS naming the ticket — any other failure fails, and once the bug is fixed
-- the test passes and stays as its guard.
--
-- Programs that read globals (M, N, L, GL, G1, MYIT) set them inside `with_globals`, which restores them: the suite
-- runs many specs in one process.
local MX = require 'cartograph.mix'
local R = require 'cartograph.algebraread'

local function ready() if not pcall(vim.treesitter.get_string_parser, '', 'lua') then skip 'no lua parser' end end
local function original(src, fname) return assert(load(src .. '\nreturn ' .. fname))() end
local DEOPT = setmetatable({}, { __tostring = function () return 'DEOPT' end })
-- mix, then load the residual -> the function, its text, the stats, the env it runs in (MIXK = the pool; MIXDEOPT
-- raises DEOPT; a global the residual WRITES lands in env, so read it with rawget)
local function mixed(src, fname, division, statics, opts)
    local text, stats, pool = MX.mix(assert(R.read(src, 'lua')), fname, division, statics or {}, opts)
    local env = setmetatable({ MIXK = pool, MIXDEOPT = function () error(DEOPT, 0) end }, { __index = _G })
    return assert(load(text, fname, 't', env))(), text, stats, env
end
-- why MX.mix refused -> the refusal text | 'ACCEPTED' | 'NOT A REFUSAL: <raw error>' (a raw Lua error or a lazy error
-- is never a refusal)
local function refusal(src, fname, division, statics, opts)
    local okm, e = pcall(MX.mix, assert(R.read(src, 'lua')), fname, division, statics or {}, opts)
    if okm then return 'ACCEPTED' end
    if type(e) == 'table' and e.refusal then return e.refusal end
    return 'NOT A REFUSAL: ' .. (type(e) == 'table' and vim.inspect(e) or tostring(e))
end
local function refuses(phrase, src, fname, division, statics, opts)
    local r = refusal(src, fname, division, statics, opts)
    ok(r:find(phrase, 1, true), ('refused by name [%s], got [%s]'):format(phrase, r))
end
-- the globals `names` are restored after fn, whatever fn did (and fn's error, or skip, is re-raised)
local function with_globals(names, fn)
    local saved = {}
    for _, k in ipairs(names) do saved[k] = rawget(_G, k) end
    local okf, err = pcall(fn)
    for _, k in ipairs(names) do rawset(_G, k, saved[k]) end
    if not okf then error(err, 0) end
end
local function sorted_keys(t)
    local ks = {}
    for k, v in pairs(t) do ks[#ks + 1] = tostring(k) .. (v == true and '' or ('=' .. tostring(v))) end
    table.sort(ks)
    return table.concat(ks, ',')
end
local function V(n) return { op = 'var', name = n } end
local function N(v) return { op = 'num', v = v } end

-- ══ A — LOWERING ═════════════════════════════════════════════════════════════════════════════════════════════════════

test('A C1 REFUSAL-CENSUS: with opts.collect every lowering refusal is collected, exactly 8, none raised (CART-1506)', function ()
    ready()
    local src = [[
local function v(a, ...) return a end
local function one(x) return x end
local function two() return 1, 2 end
local function r1(s) return v(1, string.byte(s, 1, 2)) end
local function r2(x) return v(one(x)) end
local function r3(t) return v(unpack(t)) end
local function r4(x) return v(0, two()) end
local function r5(t) for _, e in ipairs(t) do local g = function () e = 1 end end end
local function r6(d) local x; GG1, x = d end
local function r7(n) for i = 1, n do local g; function g() return g end end end
local function r8(n) for i = 1, n do local g; function g() return i end; local h = function () return g() end end end
local function r9(n) for i = 1, n do local g; local h = function () return g end; g = 1 end end
]]
    -- (r8 is NOT stale: g is assigned before any closure captures it)
    local c = {}
    MX.lower(assert(R.read(src, 'lua')), { collect = c })
    local n = {}
    for _, e in ipairs(c) do n[e.why] = (n[e.why] or 0) + 1 end
    eq({
        ['a call of the vararg function v whose last argument expands several values (the count is not known)'] = 3,
        ['a call of the vararg function v whose last argument (two) may return several values'] = 1,
        ['a closure assigning the captured loop variable `e` (rung 3: a loop variable is not boxed)'] = 1,
        ['an assignment to GG1'] = 1,
        ['a closure capturing `g`, a local of one loop iteration that the loop body assigns (rung 2: no upvalue boxes)'] = 2,
    }, n)
    eq(8, #c)
end)

test('A C2 LOWERING-BASICS: numeric for with a step, do-block, bracket key, short multi-assignment, if/else (CART-1506)', function ()
    ready()
    local src = [[
local function f(d)
  local s = 0
  for i = 1, 5, 2 do s = s + i end
  local x = 1
  do x = d end
  local y = x
  local t = { [1] = d }
  local a, b = 1, 2
  a, b = d
  local e
  if d > 0 then e = 1 else e = 2 end
  return s * 1000 + y * 100 + t[1] * 10 + e + (b == nil and 0 or 500)
end
]]
    local o = original(src, 'f')
    eq(9111, o(1)); eq(8892, o(-1))
    local r, text = mixed(src, 'f', { 'D' })
    eq(9111, r(1), text); eq(8892, r(-1), text)
end)

test('A C3 VARARG-PACK: a vararg callee packs fixed, unpacked and single-call extras in order (CART-1506)', function ()
    ready()
    local src = [[
local function v(a, ...) local b = ...; return select('#', ...) * 100 + (b or 0) end
local function one(x) return x + 1 end
local function f(x, t) return v(x, 10, 20) + v(x, 10, unpack(t)) * 1000 + v(0, one(x)) * 1000000 + v(0, 7, one(x)) * 1000000000 end
]]
    eq(207102210210, original(src, 'f')(1, { 7 }))
    local r, text = mixed(src, 'f', { 'D', 'D' })
    eq(207102210210, r(1, { 7 }), text)
end)

test('A C4 FORCE: what a mutator, an out-parameter or a closure store reaches is dynamic (CART-1506)', function ()
    ready()
    local src = [[
local function two() return {}, 0 end
local function put(o, w) o.v = w end
local function f(d)
  local t = { 3, 1, 2 }
  table.sort(t)
  local s = { items = {} }
  table.insert(s.items, d)
  local u, n = two()
  table.insert(u, d)
  table.insert(GL.list, d)
  local fill
  function fill(o, w) o.x = w end
  local q = {}
  fill(q, d)
  local p = {}
  put(p, d)
  local tt = { v = 0 }
  local set = function (x) tt.v = x end
  set(d)
  return t[1] + #s.items * 10 + (#u + n) * 100 + q.x * 1000 + p.v * 10000 + tt.v * 100000, s
end
]]
    -- (s escapes — it is returned — so it is not scalar-replaced: see CART-1510 for the SRA case)
    with_globals({ 'GL' }, function ()
        _G.GL = { list = {} }
        local ov, os_ = original(src, 'f')(1)
        eq(111111, ov); eq({ items = { 1 } }, os_)
        _G.GL = { list = {} }
        local r, text = mixed(src, 'f', { 'D' }, {}, { globals = { ['GL.list'] = _G.GL.list } })
        local v, s = r(1)
        eq(111111, v, text); eq({ items = { 1 } }, s, text)
        eq(1, #_G.GL.list, 'the insert into the global list ran once, at run time')
    end)
end)

test('A C5 TARGET-PAREN: a store through a parenthesized base `(t).x` in a closure is the right value or a refusal, never a crash (CART-1506)', function ()
    ready()
    local src = 'local function f(d)\n  local t = { x = 0 }\n  local set = function (v) (t).x = v end\n  set(d)\n  return t.x\nend\n'
    eq(5, original(src, 'f')(5))
    local why = refusal(src, 'f', { 'D' })
    if why == 'ACCEPTED' then
        local r, text = mixed(src, 'f', { 'D' })
        eq(5, r(5), text)
    else
        -- (today: refused by name. A paren base should be transparent — see CART-1509 — and this test then takes the
        -- ACCEPTED arm)
        ok(not why:find('^NOT A REFUSAL'), why)
    end
end)

test('A C6 FOR-ITER: a host iterator is never lowered as pairs; `for k in pairs(t), u` iterates u (CART-1506)', function ()
    ready()
    with_globals({ 'MYIT' }, function ()
        _G.MYIT = function (t)
            local i = 0
            return function () i = i + 1; if t[i] ~= nil then return i * 10, t[i] end end
        end
        local src = 'local function f(t)\n  local s = 0\n  for k, v in MYIT(t) do s = s + k end\n  return s\nend\n'
        eq(30, original(src, 'f')({ 4, 5 }))
        local why = refusal(src, 'f', { 'S' }, { { 4, 5 } })
        if why == 'ACCEPTED' then
            eq(30, (mixed(src, 'f', { 'S' }, { { 4, 5 } }))())
        else
            ok(why:find('the primitive MYIT', 1, true), why)
        end
    end)
    local src = 'local function f(t, u)\n  local n = 0\n  for k in pairs(t), u do n = n + k end\n  return n\nend\n'
    eq(1, original(src, 'f')({ 5, 6, 7 }, { 1 }))
    local r, text = mixed(src, 'f', { 'D', 'D' })
    eq(1, r({ 5, 6, 7 }, { 1 }), text)
end)

test('A C7 BOX: a closure-assigned local is boxed, and every read of it — table rest, callv, method object, call statement, do body — reads the box (CART-1506)', function ()
    ready()
    local src = [[
local function f(d)
  local x = d
  local y = 0
  local s = 'a'
  local g = function () return 1 end
  local set = function (v) x = v; s = 'abc'; g = function () return 2 end end
  local sety = function (v) y = v end
  set(d + 1)
  sety(x)
  local t = { tostring(x) }
  local r
  do r = x end
  return t[1] .. s:upper() .. g() .. y .. r
end
]]
    eq('6ABC266', original(src, 'f')(5))
    local r, text = mixed(src, 'f', { 'D' })
    eq('6ABC266', r(5), text)
    -- a several-value declaration of a closure-assigned variable: refused by name (rung 3), or right
    local src2 = 'local function two() return 1, 2 end\nlocal function f(d)\n  local a, b = two()\n  local set = function (v) a = v end\n  set(d)\n  return a + b\nend\n'
    eq(7, original(src2, 'f')(5))
    local why = refusal(src2, 'f', { 'D' })
    if why == 'ACCEPTED' then
        local r2, text2 = mixed(src2, 'f', { 'D' })
        eq(7, r2(5), text2)
    else
        eq('a declaration of several values whose variable a closure assigns (rung 3)', why)
    end
end)

test('A C8 TOPLEVEL: a program is top-level function declarations — a top-level `local` is refused by name (CART-1506)', function ()
    ready()
    eq('top-level variable_declaration (a program is top-level function declarations)', refusal('local x = 1\nlocal function f(d) return d end\n', 'f', { 'D' }))
end)

test('A C9 SINGLE: which program functions return exactly one value on every path (CART-1506)', function ()
    ready()
    local src = [[
local function g1(x) if x > 0 then return 1 else return 1, 2 end end
local function g2(x) if x > 0 then return 1, 2 end return 1 end
local function g3(x) return g1(x) end
local function h(x) local y = x end
local function one(x) return x end
local function g4(x) for i = 1, 2 do return i, i end return 1 end
]]
    local s = MX.lower(assert(R.read(src, 'lua'))).single
    eq({ g1 = false, g2 = false, g3 = false, h = false, one = true, g4 = false },
        { g1 = s.g1, g2 = s.g2, g3 = s.g3, h = s.h, one = s.one, g4 = s.g4 })
end)

test('A C10 SRA: a record gaining a NEW key is scalar-replaced right; the sra decision defaults to replace (CART-1506)', function ()
    ready()
    local src = 'local function f(d) local t = { a = 1 }; t.b = d; return t.a + t.b end\n'
    eq(6, original(src, 'f')(5))
    local r, text = mixed(src, 'f', { 'D' })
    eq(6, r(5), text)
    local prog = MX.lower(assert(R.read('local function f(d) local t = { a = 1 }; return t.a + d end', 'lua')), { decide = function () return nil end })
    eq(1, prog.sra.replaced)
    eq(true, prog.decisions[1] and prog.decisions[1].choice)
end)

test('A C11 WRAP: a static pcall of a closure of 0..8 parameters runs through each arity\'s wrapper (CART-1506)', function ()
    ready()
    local src = [[
local function f(d)
  local s = 0
  local _, r0 = pcall(function () return 1 end); s = s + r0
  local _, r1 = pcall(function (a) return a end, 1); s = s + r1
  local _, r2 = pcall(function (a, b) return a + b end, 1, 2); s = s + r2
  local _, r3 = pcall(function (a, b, c) return a + b + c end, 1, 2, 3); s = s + r3
  local _, r4 = pcall(function (a, b, c, e) return a + b + c + e end, 1, 2, 3, 4); s = s + r4
  local _, r5 = pcall(function (a, b, c, e, g) return a + b + c + e + g end, 1, 2, 3, 4, 5); s = s + r5
  local _, r6 = pcall(function (a, b, c, e, g, h) return a + b + c + e + g + h end, 1, 2, 3, 4, 5, 6); s = s + r6
  local _, r7 = pcall(function (a, b, c, e, g, h, i) return a + b + c + e + g + h + i end, 1, 2, 3, 4, 5, 6, 7); s = s + r7
  local _, r8 = pcall(function (a, b, c, e, g, h, i, j) return a + b + c + e + g + h + i + j end, 1, 2, 3, 4, 5, 6, 7, 8); s = s + r8
  return s + d
end
]]
    eq(121, original(src, 'f')(0))
    local r, text = mixed(src, 'f', { 'D' })
    eq(121, r(0), text)
end)

test('A C12 KNOWN: a known global is folded unless it, or an ancestor, is stored into or mutated (CART-1506)', function ()
    ready()
    local src = 'local function f(k, v)\n  M[k] = v\n  table.insert(L.list, v)\n  return M.data * 10 + N.c + #L.list * 100\nend\n'
    with_globals({ 'M', 'N', 'L' }, function ()
        _G.M = { data = 1 }; _G.N = { c = 3 }; _G.L = { list = {} }
        local r, text = mixed(src, 'f', { 'D', 'D' }, {}, { globals = { M = _G.M, ['M.data'] = 1, ['N.c'] = 3, ['L.list'] = _G.L.list } })
        -- (after mix N.c changes: the residual folded the never-stored N.c to its mix-time 3; M.data — its ancestor M is
        -- stored into — and L.list — mutated by table.insert — are read at run time)
        _G.N.c = 4
        eq(5 * 10 + 3 + 1 * 100, r('data', 5), text)
    end)
end)

test('A C13 DIRTY: a callee that writes a global runs at run time (direct or through a local alias); a pure one folds (CART-1506)', function ()
    ready()
    with_globals({ 'G1' }, function ()
        _G.G1 = nil
        local src = [[
local function g(x) G1 = x end
local function f1(x) g(x); return x end
local function f2(x) local h = g; h(x); return x end
local function e(d) return f1(1) + f2(2) + d end
]]
        local r, text, _, env = mixed(src, 'e', { 'D' })
        eq(4, r(1), text)
        eq(2, rawget(env, 'G1'), 'both writes happen at run time, the last one wins\n' .. text)
        eq(nil, rawget(_G, 'G1'), 'nothing written while specializing')
        local src2 = [[
local function g(x) G1 = x end
local function kk(x) return x end
local function k(x) local y = 0; y = math.pi * x; local z = kk(y); local w = kk; return w(z) end
local function e(d) g(d); local q = function (a) return a * 2 end; local ok, r = pcall(q, 3); return k(2) + r + d end
]]
        local r2, text2 = mixed(src2, 'e', { 'D' })
        eq(original(src2, 'e')(1), r2(1), text2)
        -- (over-marking costs no value, only quality: no pcall, no residual k, k(2) + r one constant)
        local body = vim.trim(((text2:match('function e_%d+%(d_%d+%)\n(.-)\nend') or text2):gsub('_%d+', ''):gsub('%s+', ' ')))
        eq('g(d) return (12.283185307179586 + d)', body, text2)
        ok(not text2:find('pcall', 1, true) and not text2:find('k_%d'), text2)
    end)
end)

test('A C14 DYNAMIC: the dynamic decision is offered exactly the static locals a loop makes dynamic, and never without a reason (CART-1506)', function ()
    ready()
    local src = [[
local function two() return 1, 2 end
local function it(t, i) if i < #t then return i + 1, t[i + 1] end end
local function f(d)
  local a, b = two()
  local g
  function g(x) return x + a end
  local s = 0
  for k, v in it, { 1 }, 0 do s = s + v end
  return g(d) + b + s
end
]]
    local offered = {}
    local r, text = mixed(src, 'f', { 'D' }, {}, { decide = function (kind, ctx)
        if kind == 'dynamic' then
            for _, n in ipairs(ctx.locals) do offered[#offered + 1] = n end
            return true
        end
    end })
    table.sort(offered)
    eq('a,b,s', table.concat(offered, ','))
    eq(9, original(src, 'f')(5)); eq(9, r(5), text)
    local clean = [[
local function kk(x) return x end
local function k(x) local y = 0; y = math.pi * x; return kk(y) end
local function e(d) local q = function (a) return a * 2 end; local ok, r = pcall(q, 3); return k(2) + r + d end
]]
    local _, text2, stats = mixed(clean, 'e', { 'D' })
    local kinds = {}
    for _, d in ipairs(stats.decisions or {}) do kinds[#kinds + 1] = d.kind end
    ok(not vim.tbl_contains(kinds, 'dynamic'), 'no dynamic decision: ' .. table.concat(kinds, ',') .. '\n' .. text2)
end)

test('A C15 OPTS-NAME: opts.name names the residual entry (CART-1506)', function ()
    ready()
    local text, _, pool = MX.mix(assert(R.read('local function f(d) return d + 1 end', 'lua')), 'f', { 'D' }, {}, { name = 'compiled' })
    ok(text:find('function compiled(', 1, true) and not text:find('f_%d'), text)
    eq(6, assert(load(text, 'r', 't', setmetatable({ MIXK = pool }, { __index = _G })))()(5))
end)

test('A C16 COUNT_USES: every IR op counts its uses (a lambda\'s twice) — the unfold duplication guard (CART-1506)', function ()
    ready()
    local src = 'local function sq(x) return x * x end\nlocal function f(t) return sq(table.remove(t)) end\n'
    local t = { 2, 3 }
    local r, text = mixed(src, 'f', { 'D' })
    eq(9, r(t), text)
    eq({ 2 }, t, 'table.remove ran once\n' .. text)
    local e = { op = 'table', fields = {
        { key = V'k1', val = { op = 'bin', o = '+', l = V'b1', r = V'b2' } },
        { key = N(2), val = { op = 'un', o = '-', e = V'u1' } },
        { key = N(3), val = { op = 'index', obj = V'i1', key = V'i2' } },
        { key = N(4), val = { op = 'call', fn = 'x', args = { V'c1' } } },
        { key = N(5), val = { op = 'prim', name = 'p', args = { V'p1' } } },
        { key = N(6), val = { op = 'callv', f = V'cv0', args = { V'cv1' } } },
        { key = N(7), val = { op = 'method', obj = V'm0', m = 'z', args = { V'm1' } } },
        { key = N(8), val = { op = 'lambda', params = {}, body = {
            { op = 'local', name = 'zz', e = V'L1' },
            { op = 'callstmt', e = { op = 'prim', name = 'p', args = { V'L2' } } },
            { op = 'assign', target = V'L3', e = V'L4' },
            { op = 'if', clauses = { { cond = V'L5', body = { { op = 'ret', es = { V'L6' } } } } }, els = { { op = 'ret', es = { V'L7' } } } },
            { op = 'forin', kind = 'pairs', e = V'L8', kname = 'kk', body = { { op = 'ret', es = { V'L9' } } } },
            { op = 'while', cond = V'L10', body = {} },
            { op = 'break' },
        } } } },
        rest = V'r1' }
    local u = {}
    MX.count_uses(e, u)
    eq('L10=2,L1=2,L2=2,L3=2,L4=2,L5=2,L6=2,L7=2,L8=2,L9=2,b1=1,b2=1,c1=1,cv0=1,cv1=1,i1=1,i2=1,k1=1,m0=1,m1=1,p1=1,r1=1,u1=1', sorted_keys(u))
end)

test('A C17 BOUND_NAMES: every binder of a nested lambda is reported, exactly (CART-1506)', function ()
    ready()
    local e = { op = 'call', fn = 'q', args = { { op = 'lambda', params = { 'p1' }, body = {
        { op = 'local', name = 'l1', e = V'x1' },
        { op = 'localm', names = { 'm1' }, es = { V'x2' } },
        { op = 'fornum', name = 'n1', from = V'x3', to = V'x4', step = N(1), body = {} },
        { op = 'forin', kind = 'pairs', e = V'x5', kname = 'k1', vname = 'v1', body = {} },
        { op = 'forgen', names = { 'g1' }, es = { V'x6' }, body = {} },
    } } } }
    eq('g1,k1,l1,m1,n1,p1,v1', sorted_keys(MX.bound_names(e, {})))
end)

-- ══ B — EVALUATOR + BTA ══════════════════════════════════════════════════════════════════════════════════════════════

test('B C-EVAL: the static evaluator runs break, if/else, ipairs/pairs, a generic for, `and`, a method — results folded (CART-1506)', function ()
    ready()
    local src = [[
local function none() end
local function brk(n)
    local s = 0
    for i = 1, 10 do
        if i > n then break end
        s = s + i
    end
    return s
end
local function ifelse(n)
    local s
    if n > 0 then s = 1 else s = 2 end
    return s
end
local function elseret(n)
    if n > 0 then return 1 else return 2 end
end
local function sum2(t)
    local s = 0
    for _, v in ipairs(t) do s = s + v end
    for _, v in pairs(t) do s = s + v * 100 end
    return s
end
local function count(t)
    local n = 0
    for k in pairs(t) do n = n + 1 end
    return n
end
local function iter(t, i)
    i = i + 1
    local v = t[i]
    if v then return i, v end
end
local function gen(t)
    local s = 0
    for i, v in iter, t, 0 do s = s + v end
    return s
end
local function andf(s) return tostring(s and 1) end
local function meth(k)
    local o = { k = k, get = function (self) return self.k end }
    return o:get()
end
local function f(t, x)
    return select('#', none()) .. '|' .. brk(3) .. '|' .. ifelse(5) .. '|' .. elseret(-1) .. '|' .. sum2(t) .. '|' .. count(t)
        .. '|' .. gen(t) .. '|' .. andf(false) .. '|' .. meth(7) .. '|' .. x
end
]]
    local T = { 10, 20, 30, k = 5 }
    eq('0|6|1|2|6560|4|60|false|7|!', original(src, 'f')(T, '!'))
    local r, text = mixed(src, 'f', { 'S', 'D' }, { T })
    eq('0|6|1|2|6560|4|60|false|7|!', r('!'), text)
    -- (a method call passes exactly its arguments: `("%s"):format()` has no 2nd one, and raises as in Lua)
    local src2 = 'local function f(x)\n    return ("%s"):format() .. x\nend\n'
    eq(false, (pcall(original(src2, 'f'), 'a')))
    eq(false, (pcall((mixed(src2, 'f', { 'D' })), 'a')))
end)

test('B C-PINS: a closure made in a loop pins its iteration\'s locals, nil included; an assumption selects its arm (CART-1506)', function ()
    ready()
    local src = [[
local function mk(n)
    local fs, gs = {}, {}
    for i = 1, n do
        local k = i * 10
        fs[i] = function () return k end
        local m = nil
        if i == 2 then m = 5 end
        gs[i] = function () return m end
    end
    return fs, gs
end
local function f(x, n)
    local fs, gs = mk(n)
    return fs[1]() + (gs[1]() or 0) + x
end
]]
    eq(11, original(src, 'f')(1, 2))
    local r, text = mixed(src, 'f', { 'D', 'S' }, { nil, 2 })
    eq(11, r(1), text)
    -- (assume the value that SELECTS the guarded arm: nil takes the other one)
    local src2 = 'local function f(x)\n    if x.kind == "big" then\n        return x.a * 1000 + x.b * 100 + x.c\n    end\n    return x.a\nend\n'
    local r2, text2 = mixed(src2, 'f', { 'D' }, {}, { assume = { kind = { value = 'big' } } })
    ok(text2:find('1000', 1, true), 'the big arm is kept\n' .. text2)
    eq(1203, original(src2, 'f')({ kind = 'big', a = 1, b = 2, c = 3 }))
    eq(1203, r2({ kind = 'big', a = 1, b = 2, c = 3 }), text2)
    local okr, e = pcall(r2, { kind = 'small', a = 7 })
    eq(false, okr); eq(DEOPT, e)
end)

test('B C-ERRMAP: a static error() at level 1, and with a TABLE error object, under a line map (CART-1506)', function ()
    ready()
    local lines = {}
    for n = 1, 20 do lines[n] = { src = 'orig.lua', line = 100 + n } end
    local src = 'local function bad1(x)\n    error("bad " .. x, 1)\nend\nlocal function bad2(x)\n    error({ code = x })\nend\nlocal function f(x, d)\n    local ok1, w1 = pcall(bad1, x)\n    local ok2, w2 = pcall(bad2, x)\n    return w1 .. "|" .. tostring(w2.code) .. d\nend\n'
    local r, text = mixed(src, 'f', { 'S', 'D' }, { 7 }, { lines = lines })
    -- (`error` is on the source's line 2 -> orig.lua:102)
    eq('orig.lua:102: bad 7|7!', r('!'), text)
end)

test('B C-REFUSE: what is refused by name stays refused — not accepted, not a raw Lua error (CART-1506)', function ()
    ready()
    local function body(b) return 'local function f(x)\n' .. b .. '\nend\n' end
    -- would become an ACCEPTED residual
    refuses('no closure of the program', body('    local g = 5\n    return g(1) .. x'), 'f', { 'D' })
    refuses('the primitive os.time', body('    return os.time() .. x'), 'f', { 'D' })
    refuses('the method `nope` of a string', body('    return ("x"):nope() .. x'), 'f', { 'D' })
    refuses('the global NOPE', 'local function g() return NOPE end\n' .. body('    return tostring(g()) .. x'), 'f', { 'D' })
    refuses('the global NOPE', 'local function g() return NOPE end\n' .. body('    local ok = pcall(g)\n    return tostring(ok) .. x'), 'f', { 'D' })
    refuses('stored into by a closure', 'local function mk() return {}, 1 end\n' .. body('    local put = function (t, v) t.k = v + x return t.k end\n    return put(mk())'), 'f', { 'D' })
    refuses('long-bracket', body('    return [[ab]] .. x'), 'f', { 'D' })
    refuses('the escape \\z', body('    return "\\zab" .. x'), 'f', { 'D' })
    -- would become a RAW Lua error
    refuses('reaches no value', body('    return nosuch.thing(x)'), 'f', { 'D' })
    refuses('no closure of the program', 'local function g(it, x) return it() .. x end\n' .. body('    return g(("ab"):gmatch("%a"), x)'), 'f', { 'D' })
    refuses('expands several dynamic values', 'local function g(a, b, c) return b end\n' .. body('    local it = ("ab"):gmatch("%a")\n    return g(1, it(x))'), 'f', { 'D' })
    refuses('beyond a byte', body('    return "\\256" .. x'), 'f', { 'D' })
    -- a program primitive is never CALLED while specializing
    local n = 0
    local prims = { ['P.get'] = function () n = n + 1; return function (y) return y end end }
    refuses('expands several dynamic values', 'local function g(a, b, c) return b end\n' .. body('    return g(1, P.get()(x))'), 'f', { 'D' }, {}, { prims = prims })
    eq(0, n, 'P.get called while specializing')
    -- accepted, exactly: the byte boundary and a hex escape on its own
    eq('\255!', (mixed(body('    return "\\255" .. x'), 'f', { 'D' }))('!'))
    eq('A!', (mixed(body('    return "\\x41" .. x'), 'f', { 'D' }))('!'))
end)

test('B C-STEPS: MX.run counts the interpreter\'s steps — the payoff gate\'s measure and the budget\'s unit (CART-1506)', function ()
    ready()
    local p = MX.lower(assert(R.read('local function g() return 1 end\nlocal function f()\n    local s = 0\n    for i = 1, 3 do s = s + g() end\n    return s\nend\n', 'lua')))
    local v, steps = MX.run(p, 'f', {}, 1e7)
    eq(3, v); eq(26, steps)
end)

test('B C-BTA: what folds, what is dynamic, and the fixpoint over loops and do-blocks (CART-1506)', function ()
    ready()
    local function nolocal(text, name) ok(not text:find(name .. '_%d+'), 'static `' .. name .. '` survives\n' .. text) end
    local function same(src, fname, division, statics, args, want)
        eq(want, original(src, fname)(unpack(args)))
        local r, text = mixed(src, fname, division, statics)
        local a = {}
        for i, d in ipairs(division) do if d == 'D' then a[#a + 1] = args[i] end end
        eq(want, r(unpack(a)), text)
        return text
    end
    -- a static closure folds: through a table, compared with itself, passed to a static pcall
    local text = same('local function f(s, x)\n    local g = function () return s end\n    local t = { g }\n    return t[1]() + x\nend\n', 'f', { 'S', 'D' }, { 1 }, { 1, 2 }, 3)
    ok(not text:find('function ()', 1, true) and not text:find('t_', 1, true), text)
    same('local function f(s, x)\n    local g = function () return s end\n    if g == g then return x end\n    return 0\nend\n', 'f', { 'S', 'D' }, { 1 }, { 1, 5 }, 5)
    text = same('local function f(s, x)\n    local g = function () return s end\n    local ok, v = pcall(g)\n    return v + x\nend\n', 'f', { 'S', 'D' }, { 1 }, { 1, 2 }, 3)
    ok(not text:find('function ()', 1, true) and not text:find('pcall', 1, true), text)
    -- a static multi-assignment folds; a store target makes its root dynamic
    text = same('local function f(x)\n    local a, b = 1, 2\n    a, b = b, a\n    return a * 10 + b + x\nend\n', 'f', { 'D' }, {}, { 0 }, 21)
    nolocal(text, 'a'); nolocal(text, 'b')
    same('local function f(x)\n    local t = { k = 0 }\n    local y\n    t.k, y = x, x\n    return t.k + y\nend\n', 'f', { 'D' }, {}, { 5 }, 10)
    -- (a store through a call's result is refused by name: whether the call returns a fresh table is unknown — CART-1509)
    refuses('a store into a table reached through mk(x)', 'local function mk(x) return {} end\nlocal function f(x)\n    local y\n    mk(x).k, y = x, x\n    return y\nend\n', 'f', { 'D' })
    local r, text2 = mixed('local function f(x)\n    local t = { k = 0 }\n    local y\n    t.k, y = x, x\n    return t, y\nend\n', 'f', { 'D' })
    local t, y = r(5)
    eq(5, t.k, text2); eq(5, y, text2)
    -- a static break keeps its loop static: the sum folds
    text = same('local function f(x, n)\n    local s = 0\n    for i = 1, 10 do\n        if i > n then break end\n        s = s + i\n    end\n    return s + x\nend\n', 'f', { 'D', 'S' }, { nil, 3 }, { 1, 3 }, 7)
    nolocal(text, 's')
    -- do-blocks and loops reach the fixpoint
    same('local function f(x)\n    do\n        local z = x * 2\n        x = z\n    end\n    return x\nend\n', 'f', { 'D' }, {}, { 3 }, 6)
    same('local function f(x)\n    local a, b, c = 0, 0, 0\n    for i = 1, 3 do\n        do\n            c = b\n            b = a\n            a = x\n        end\n    end\n    return c\nend\n', 'f', { 'D' }, {}, { 7 }, 7)
    same('local function f(x)\n    local a, b = 0, 0\n    for i = 1, 3 do b = a; a = x end\n    return b\nend\n', 'f', { 'D' }, {}, { 7 }, 7)
    -- an EFFECT stays residual: the error is raised at run time, with the program's own table
    local src = 'local function f(x)\n    if x then error({ code = 1 }) end\n    return 1\nend\n'
    local r3, text3 = mixed(src, 'f', { 'D' })
    eq(1, r3(false), text3)
    local okr, e = pcall(r3, true)
    eq(false, okr); eq(1, type(e) == 'table' and e.code)
    -- M.bta reads opts.globals: a known global is static
    local prog = MX.lower(assert(R.read('local function f(x)\n    local y = K\n    return y + x\nend\n', 'lua')))
    local bt = MX.bta(prog, 'f', { 'D' }, { globals = { K = 5 } })
    local yb
    for id, b in pairs(bt) do if prog.names[id] == 'y' then yb = b end end
    eq('S', yb)
end)

test('B C-DEPTH: a static value nested deeper than 20 — through tables, keys and closures — is refused by name (CART-1506)', function ()
    ready()
    local function chain(n) local t = { v = 1 } for _ = 2, n do t = { a = t } end return t end
    local src = [[
local function g(t, x) return x end
local function mk(t) return function () return t end end
local function wrap(c) return function () return c() end end
local function f(t, x) return g(t, x) end
local function fc(t, x) return g(mk(t), x) end
local function fw(t, x) return g(wrap(mk(t)), x) end
]]
    -- (a closure argument that cannot be keyed is LIFTED by the 'grow' decision; vetoed, the refusal shows)
    local NOGROW = { decide = function (kind) if kind == 'grow' then return false end end }
    local function acc(fname, v) eq(4, (mixed(src, fname, { 'S', 'D' }, { v }, NOGROW))(4), fname) end
    local function ref(fname, v) refuses('nested deeper than 20', src, fname, { 'S', 'D' }, { v }, NOGROW) end
    acc('f', chain(21)); ref('f', chain(22))
    acc('f', { [chain(20)] = true }); ref('f', { [chain(21)] = true })
    ref('f', { a = { [chain(20)] = true } })
    acc('fc', chain(20)); ref('fc', chain(21))
    ref('fw', chain(20))
end)

test('B C-TERM: config_term\'s 20000-node budget, cycles, closures; embeds (CART-1506)', function ()
    ready()
    local function big(n) local t = {} for i = 1, n do t[i] = i end return t end
    -- (1 + 2N vterm calls per table of N scalar pairs)
    ok(MX.config_term('g', { 'S', 'S' }, { big(9999), 1 }, {}) ~= nil, '20000 nodes: a term')
    eq(nil, MX.config_term('g', { 'S' }, { big(10000) }, {}), '20001 nodes')
    local t = {}; t.self = t
    local term = MX.config_term('g', { 'S' }, { t }, {})
    ok(term, 'a cyclic table has a term')
    eq('cycle', term.kids[1].kids[1].kids[2].k)
    local fn, fn2 = function () end, function () end
    local clos = {
        [fn] = { lam = { id = 7, free = { 1, 2 } }, bt = { [2] = 'D' }, env = { [1] = 5, [2] = 'dyn' } },
        [fn2] = { lam = { id = 8, free = { 1 } }, bt = {}, env = { [1] = big(10000) } },
    }
    term = MX.config_term('g', { 'S', 'S', 'D' }, { fn, print }, clos)
    ok(term, 'a term')
    local c = term.kids[1]
    eq('clo:7', c.k); eq(2, #c.kids)
    eq('lit', c.kids[1].k); eq(5, c.kids[1].v)
    eq('hole', c.kids[2].k); eq('v2', c.kids[2].h)
    eq('function', term.kids[2].k, 'a host function')
    eq('hole', term.kids[3].k)
    eq(nil, MX.config_term('g', { 'S' }, { fn2 }, clos), 'a closure over a too-big value')
    local a, b = { k = 'lit', v = 1 }, { k = 'lit', v = 2 }
    local memo = {}
    eq(true, MX.embeds(a, b, memo)); eq(true, MX.embeds(a, b, memo), 'a memo hit')
    eq(true, MX.embeds(a, { k = 'tbl', kids = { { k = 'kv', kids = { { k = 'lit', v = 'a' }, { k = 'lit', v = 2 } } } } }), 'a number dives into a table')
end)

test('B C-SINGLE: a call through a known closure as the last argument is accepted only when single-valued on every path (CART-1506)', function ()
    ready()
    local src = [[
local function g(a, b, c) return tostring(b) .. "/" .. tostring(c) end
local function one(y) return y + 1 end
local function two(y) return y, y + 1 end
local function fa(x)
    local k = function (y) return y + 1 end
    return g(1, k(x))
end
local function ff(x)
    local k = function (y) return one(y) end
    return g(1, k(x))
end
local function fb(x)
    local k = function (y) return y, y + 1 end
    return g(1, k(x))
end
local function fe(x)
    local k = function (y) return two(y) end
    return g(1, k(x))
end
local function fp(x)
    local k = function (y) return string.find(y, "b") end
    return g(1, k(x))
end
local function fels(x)
    local k = function (y)
        if y then return y else return y, 1 end
    end
    return g(1, k(x))
end
local function fcl(x)
    local k = function (y)
        if y then return y, 1 end
        return y
    end
    return g(1, k(x))
end
]]
    for _, fname in ipairs({ 'fa', 'ff' }) do
        eq('5/nil', original(src, fname)(4))
        local r, text = mixed(src, fname, { 'D' })
        eq('5/nil', r(4), fname .. '\n' .. text)
    end
    for _, fname in ipairs({ 'fb', 'fe', 'fp', 'fels', 'fcl' }) do refuses('expands several dynamic values', src, fname, { 'D' }) end
end)

test('B C-UNIT: the binding-time invariant\'s guards at the exported surface — evaluator and _serialize (CART-1506)', function ()
    ready()
    local prog = MX.lower(assert(R.read('local function f(x)\n    return x\nend\n', 'lua')))
    local id = prog.funcs.f.params[1]
    local okv, e = pcall(MX.evaluator(prog).eval, { op = 'var', id = id }, { [id] = MX.DYN })
    eq(false, okv); ok(type(e) == 'table' and tostring(e.refusal):find('binding-time gap', 1, true), vim.inspect(e))
    local fn = function () end
    local clos = { [fn] = { lam = { id = 7, free = { 1 } }, bt = { [1] = 'D' }, env = { [1] = 'dynval' } } }
    eq('λ7{1:D}', MX._serialize(fn, 0, clos))
    local okv2, e2 = pcall(MX._serialize, fn, 0, clos, nil, true)
    eq(false, okv2); ok(type(e2) == 'table' and tostring(e2.refusal):find('rung 2', 1, true), vim.inspect(e2))
end)

-- ══ C — SPECIALIZER ══════════════════════════════════════════════════════════════════════════════════════════════════
-- (left out on purpose: three probes where the original REFUSES conservatively and the mutant computes the CORRECT answer
-- — the non-embedding whistle recursion (mix.lua 2194), the mixed `local a, b = two()` (2520), and the 30-step static cons
-- list (2384, CART-1518). Pinning those refusals would pin a limitation.)

local LINES = {}
for i = 1, 40 do LINES[i] = { src = 'o.lua', line = 100 + i } end
-- the decisions of one kind a mix logged
local function decisions(stats, kind)
    local out = {}
    for _, d in ipairs(stats.decisions or {}) do if d.kind == kind then out[#out + 1] = d end end
    return out
end

test('C C1 BUDGET: opts.budget counts unfold steps from 0, charges statements and expressions, refuses past it (CART-1506)', function ()
    ready()
    local src = 'local function f(x) return x end\n'
    local r, text, stats = mixed(src, 'f', { 'D' }, {}, { budget = 2 })
    eq(2, stats.unfold_steps, text); eq(5, r(5), text)
    refuses('the unfold budget (1)', src, 'f', { 'D' }, {}, { budget = 1 })
end)

test('C C2 DEPTH: opts.depth counts points, unfolds and lifts — entered and restored — exactly (CART-1506)', function ()
    ready()
    -- (needs exactly depth 3: point f, then p, the lifted k, and g -> h, each restored after)
    local src = [[
local function h(y) return y + 1 end
local function g(y) return h(y) end
local function p(y)
  local z = y
  return z
end
local function f(x)
  local a = p(x)
  local k = function () return x end
  return k, g(a)
end
]]
    local ok_, ov = original(src, 'f')(5)
    eq(5, ok_()); eq(6, ov)
    local r, text = mixed(src, 'f', { 'D' }, {}, { depth = 3 })
    local k, v = r(5)
    eq('function', type(k), text); eq(5, k(), text); eq(6, v, text)
    refuses('the specialization depth (2 nested unfolds', src, 'f', { 'D' }, {}, { depth = 2 })
end)

test('C C3 DECISION CTX: the decision hook\'s ctx — fn, division, at, chain, shape, callee, proven, configs (CART-1501) (CART-1506)', function ()
    ready()
    -- a. 'unfold'
    local U = 'local function sq(y) return y * y end\nlocal function f(x) return sq(x) + 1 end\n'
    local _, text, stats = mixed(U, 'f', { 'D' })
    local d = decisions(stats, 'unfold')
    eq(1, #d, text)
    eq({ fn = 'sq', division = 'D', at = 1, chain = { 'f' } }, d[1].ctx)
    _, text, stats = mixed(U, 'f', { 'D' }, {}, { lines = LINES })
    eq('o.lua:101', decisions(stats, 'unfold')[1].ctx.at, text)
    -- b. 'pool': the shape summary, bounded, keys sorted
    local P = 'local function f(t, x) return t[x], t[x] end\n'
    for _, c in ipairs({
        { { 'a', 'b' }, '#2{1,2}' },
        { { 'a', 'b', 'c', 'd', 'e', 'f', 'g' }, '#7{1,2,3,4,5,6}' },
        { { z = 1, y = 2, x = 3, w = 4, v = 5 }, '#0{v,w,x,y,z}' },
    }) do
        _, text, stats = mixed(P, 'f', { 'S', 'D' }, { c[1] })
        d = decisions(stats, 'pool')
        eq(1, #d, text); eq(c[2], d[1].ctx.shape)
    end
    -- c. 'single': proven, then unproven under a hook that answers true
    local S = 'local function one(x) return x + 1 end\nlocal function g(a, b, c) if b == nil and c == nil then return a end return -1 end\n'
        .. 'local function f(x)\n  local h = function (y) return y * 2 end\n  return g(one(x)) + g(h(x))\nend\n'
    _, text, stats = mixed(S, 'f', { 'D' })
    d = decisions(stats, 'single')
    eq(2, #d, text)
    eq({ { 'f', 'one', true }, { 'f', 'h', true } }, { { d[1].ctx.fn, d[1].ctx.callee, d[1].ctx.proven }, { d[2].ctx.fn, d[2].ctx.callee, d[2].ctx.proven } })
    local SD = { decide = function (kind) if kind == 'single' then return true end end }
    local G2 = 'local function g(a, b) if b == nil then return a end return -1 end\n'
    _, text, stats = mixed(G2 .. 'local function f(x) return g(string.upper(x)) end\n', 'f', { 'D' }, {}, SD)
    eq({ fn = 'f', division = 'D', at = 2, chain = {}, callee = 'string.upper' }, decisions(stats, 'single')[1].ctx, text)
    _, text, stats = mixed(G2 .. 'local function f(x) return g(string.upper(x)) end\n', 'f', { 'D' }, {},
        { lines = LINES, decide = SD.decide })
    eq('o.lua:102', decisions(stats, 'single')[1].ctx.at, text)
    _, text, stats = mixed(G2 .. 'local function f(x)\n  local h = function (y) return y, y end\n  return g(h(x))\nend\n', 'f', { 'D' }, {}, SD)
    eq('h', decisions(stats, 'single')[1].ctx.callee, text)
    _, text, stats = mixed(G2 .. 'local function f(x) return g(x:upper()) end\n', 'f', { 'D' }, {}, SD)
    eq('method', decisions(stats, 'single')[1].ctx.callee, text)
    -- d. 'grow': the chain of the growing recursion
    local GK = 'local function g(x, k)\n if x > 0 then return g(x - 1, function (y) return k(y) + 1 end) end\n return k(x)\nend\n'
        .. 'local function f(x) return g(x, function (y) return y end) end\n'
    _, text, stats = mixed(GK, 'f', { 'D' }, {}, { depth = 8 })
    eq({ 'g', 'g', 'g', 'g', 'g', 'g', 'g', 'f' }, decisions(stats, 'grow')[1].ctx.chain, text)
    -- e. 'generalize': both configurations are in the context (this oscillating recursion was REFUSED by the whistle
    -- until the embedding requirement went, CART-1506's investigation: it is generalized now — `n` and `b`)
    local W = 'local function walk(t, n, b)\n if n > #t then return 0 end\n return t[n] + walk(t, n + 1, not b)\nend\nlocal function f(t) return walk(t, 1, true) end\n'
    local seen = {}
    pcall(MX.mix, assert(R.read(W, 'lua')), 'f', { 'D' }, {}, { decide = function (kind, ctx, def)
        if kind == 'generalize' then seen[#seen + 1] = { ctx.configs and ctx.configs.ancestor ~= nil, ctx.configs and ctx.configs.candidate ~= nil, def } end
    end })
    ok(#seen > 0, 'a generalize decision was offered')
    for _, s in ipairs(seen) do eq({ true, true, { [2] = true, [3] = true } }, s) end
    _, text, stats = mixed(GK, 'f', { 'D' })
    d = decisions(stats, 'generalize')
    ok(#d > 0, 'generalize decisions\n' .. text)
    for _, g in ipairs(d) do
        eq(false, g.default)
        ok(g.ctx.configs and g.ctx.configs.ancestor ~= nil and g.ctx.configs.candidate ~= nil, 'both configs')
    end
end)

test('C C4 STATIC VALUES REACHING DYNAMIC CODE: NaN lifted, a table pooled once, a host value by its global path or refused by name (CART-1506)', function ()
    ready()
    local r, text = mixed('local function f(x) return x, 0 / 0 end\n', 'f', { 'D' })
    local a, nan = r(1)
    eq(1, a, text); ok(nan ~= nan, 'NaN\n' .. text)
    local P = 'local function f(t, x) return t[x], t[x] end\n'
    local stats, env
    r, text, stats, env = mixed(P, 'f', { 'S', 'D' }, { { 'a', 'b' } })
    eq({ 'b', 'b' }, { r(2) }, text)
    ok(text:find('MIXK%[1%]%[x_%d+%], MIXK%[1%]%[x_%d+%]'), 'one pooled table, referenced twice\n' .. text)
    eq(1, #rawget(env, 'MIXK')); eq(1, #decisions(stats, 'pool'))
    local G1 = { globals = { ['G.up'] = string.upper } }
    r, text = mixed('local function f(x)\n local g = G.up\n return g(x)\nend\n', 'f', { 'D' }, {}, G1)
    eq('AB', r('ab'), text); ok(text:find('MIXK[1](x', 1, true), text)
    r, text = mixed('local function f(x)\n local g = G.up\n return g, x\nend\n', 'f', { 'D' }, {}, G1)
    eq(string.upper, (r(3)), text); ok(text:find('MIXK[1]', 1, true), text)
    refuses('a static host function reaches dynamic code', 'local function g() return G.up end\nlocal function f(x) return g() end\n', 'f', { 'D' }, {}, G1)
    refuses('a static userdata reaches dynamic code', 'local function f(x) return G.h, x end\n', 'f', { 'D' }, {}, { globals = { ['G.h'] = io.stdout } })
    with_globals({ 'G' }, function ()
        _G.G = { t = { 'a', 'b', sub = { 'c', 'd' } } }
        r, text, _, env = mixed('local function f(x) return G.t[x] end\n', 'f', { 'D' }, {}, { globals = { ['G.t'] = { 'a', 'b' } } })
        ok(text:find('G.t[x_1]', 1, true), 'a known global by its path\n' .. text)
        eq(0, #rawget(env, 'MIXK')); eq('b', r(2))
        r, text, _, env = mixed('local function f(x)\n local k = "sub"\n return G.t[k][x]\nend\n', 'f', { 'D' }, {}, { globals = { ['G.t'] = { sub = { 'a', 'b' } } } })
        ok(text:find('G.t["sub"][x_1]', 1, true), 'an index path from a known global\n' .. text)
        eq(0, #rawget(env, 'MIXK')); eq('d', r(2))
    end)
    refuses('a static host value reaching dynamic code by no path from a known global', 'local function f(x)\n local n = 5\n return n(x)\nend\n', 'f', { 'D' })
end)

test('C C5 UNFOLD MEMO: configurations sharing an inlined residual stay apart, and a memo hit stays inlined (CART-1506)', function ()
    ready()
    local src = 'local function ap(k) return k() end\nlocal function tw(v, n) return ap(function () return v end) + n end\nlocal function f(x, y) return tw(x, 1) + tw(y, 2) end\n'
    eq(10, original(src, 'f')(3, 4))
    local r, text, stats = mixed(src, 'f', { 'D', 'D' })
    eq(10, r(3, 4), text); eq(1, stats.functions, text)
    -- (near the depth limit only the memo keeps the helper sq inlined)
    local src2 = [[
local function hp(y, k)
  local z = y + k
  return z
end
local function sq(y) return y * y end
local function g(x, k)
  local a = hp(x, 1)
  local b = hp(x, 2)
  local c = sq(x)
  if x > 0 then return g(x - 1, function (y) return k(y) + 1 end) end
  return k(x) + a + b + c
end
local function f(x)
  return g(x, function (y) return y end)
end
]]
    eq(6, original(src2, 'f')(3))
    local r2, text2 = mixed(src2, 'f', { 'D' })
    eq(6, r2(3), text2)
    ok(not text2:find('sq_%d+%('), 'sq is inlined everywhere\n' .. text2)
end)

test('C C6 OPTS-NAME: opts.name names the entry point, and only it (CART-1506)', function ()
    ready()
    local src = 'local function count(x, n)\n    if x > 0 then return count(x - 1, n + 1) end\n    return n\nend\nlocal function pair(x, y)\n    return count(x, 0) + count(4, y)\nend\n'
    eq(12, original(src, 'pair')(3, 5))
    local r, text = mixed(src, 'pair', { 'D', 'D' }, {}, { name = 'entry' })
    ok(text:find('^local entry,') and text:find('\nfunction entry%(') and text:find('return entry%s*$'), text)
    local first = text:match('\nfunction ([%w_]+)%(')
    eq('entry', first, text)
    eq(12, r(3, 5), text)
end)

test('C C7 WHISTLE/GROW: growth is detected at every parameter position — the first one included (CART-1506)', function ()
    ready()
    local EXT = 'local function extend(p, e)\n  local q = {}\n  for i, x in ipairs(p) do q[i] = x end\n  q[#q + 1] = e\n  return q\nend\n'
    local function gen(src)
        local r, text, stats = mixed(src, 'f', { 'D' })
        local d = decisions(stats, 'generalize')
        ok(#d > 0, 'generalized\n' .. text)
        return r, text, d[1]
    end
    -- (a) the accumulator that turns dynamic is the FIRST parameter
    local A = EXT .. 'local function walk(acc, n, path)\n  if n > 0 then return walk(acc + n, n - 1, extend(path, "P")) end\n  return acc + #path\nend\nlocal function f(n) return walk(0, n, {}) end\n'
    eq(20, original(A, 'f')(5))
    local r, text, d = gen(A)
    eq({ [3] = true }, d.default, text); eq('SDS', d.ctx.ancestor, text)
    eq(20, r(5), text)
    -- (b) the growth is in parameter 1
    local B = EXT .. 'local function walk(path, n)\n  if n > 0 then return walk(extend(path, "P"), n - 1) end\n  return #path\nend\nlocal function f(n) return walk({}, n) end\n'
    eq(5, original(B, 'f')(5))
    r, text, d = gen(B)
    eq({ [1] = true }, d.default, text)
    eq(5, r(5), text)
    -- (c) a growing CLOSURE in parameter 1
    local C = 'local function g(k, x)\n    if x > 0 then return g(function (y) return k(y) + 1 end, x - 1) end\n    return k(x)\nend\n'
        .. 'local function f(x)\n    return g(function (y) return y end, x)\nend\n'
    r, text = mixed(C, 'f', { 'D' })
    eq(3, r(3), text); eq(0, r(0), text)
end)

test('C C8 EAGER REUSE + EXPANDING LAST ARGUMENTS: values land on their parameters; eager reuse folds only instances (CART-1506)', function ()
    ready()
    local src = 'local function two() return 1, 2 end\nlocal function g(a, b, c, d) return a + b + c + (d or 0) end\nlocal function f(x) return g(x, two()) end\n'
    eq(13, original(src, 'f')(10))
    eq(13, (mixed(src, 'f', { 'D' }))(10))
    local K = 'local function count(k, x, n)\n    if x > 0 then return count(k, x - 1, n + 1) end\n    return n + k\nend\n'
        .. 'local function pair(x, y)\n    return count(1, x, 0) + count(2, 4, y) + count(1, 4, y)\nend\n'
    eq(25, original(K, 'pair')(3, 5))
    local r, text, stats = mixed(K, 'pair', { 'D', 'D' }, {}, { reuse = 'eager' })
    eq(25, r(3, 5), text); eq(3, stats.functions, text)
    -- (count(1, 4, y) is an instance of count(1, x, 0): folded onto it with k specialized away; count(2, 4, y) is not:
    -- unrolled)
    local calls = {}
    for a in text:gmatch('count_%d+(%b())') do calls[#calls + 1] = a end
    ok(vim.tbl_contains(calls, '(4, y_' .. (text:match('y_(%d+)') or '?') .. ')'), 'count(1, 4, y) folds as count_N(4, y)\n' .. text)
    local fours = 0
    for _, a in ipairs(calls) do if a:find('^%(4,') then fours = fours + 1 end end
    eq(1, fours, 'only ONE call with 4 is folded\n' .. text)
    local SEED = 'local function count(y, x, n)\n    if x > 0 then return count(y, x - 1, (n or 0) + 1) end\n    return (n or 0) + y\nend\n'
        .. 'local function seed() return 4, 0 end\nlocal function one() return 4 end\n'
    for _, c in ipairs({ { 'seed', '0' }, { 'one', 'nil' } }) do
        local s = SEED .. 'local function pair(x, y)\n    return count(y, x, 0) + count(y, ' .. c[1] .. '())\nend\n'
        eq(17, original(s, 'pair')(3, 5))
        local r2, text2 = mixed(s, 'pair', { 'D', 'D' }, {}, { reuse = 'eager' })
        eq(17, r2(3, 5), text2)
        ok(text2:find('count_%d+%(y_%d+, 4, ' .. c[2] .. '%)'), ('count_N(y, 4, %s)\n'):format(c[2]) .. text2)
    end
end)

test('C C9 TRANSACTION ROLLBACK: a refused unfold rolls the memo log back exactly — the refusal stays a refusal (CART-1506)', function ()
    ready()
    local H = 'local function h(a, b, c) return a end\nlocal function two(x) return x, x end\nlocal function p2(x)\n  local z = x\n  return z\nend\n'
        .. 'local function p3(x)\n  local z = x + 1\n  return z\nend\nlocal function sq(x) return x * x end\nlocal function cu(x) return x * x * x end\n'
    local Q = 'local function q(x) return h(x, two(x)) end\n'
    local T = 'local function g(x) return inner(x) end\nlocal function top(x) return g(x) end\n'
    for _, src in ipairs({
        H .. Q .. 'local function inner(x)\n  local v1 = p2(x)\n  return q(v1)\nend\n' .. T,
        H .. Q .. 'local function inner(x)\n  local v1 = p2(x)\n  local v2 = p3(x)\n  local v3 = sq(x)\n  return q(v1 + v2 + v3)\nend\n' .. T,
        H .. 'local function inner(x)\n  local v1 = p2(x)\n  local v2 = sq(x)\n  local v3 = p3(x)\n  local v4 = cu(x)\n  return h(v1 + v2 + v3 + v4, two(x))\nend\n' .. T,
    }) do
        refuses('the last argument of a call expands several dynamic values into its parameters (rung 3)', src, 'top', { 'D' })
    end
end)

test('C C10 ITERATION SCOPE: a closure capturing a dynamic local of one loop iteration, called after the loop, is refused or right (CART-1506)', function ()
    ready()
    local src = 'local function use(k)\n  local r = k()\n  return r\nend\nlocal function f(x)\n  local k\n  for i = 1, 2 do\n    local y = x + i\n    k = function () return y end\n  end\n  return use(k)\nend\n'
    eq(3, original(src, 'f')(1))
    local why = refusal(src, 'f', { 'D' })
    if why == 'ACCEPTED' then
        local r, text = mixed(src, 'f', { 'D' })
        eq(3, r(1), text)
    else
        ok(why:find('a closure capturing a dynamic local of one loop iteration', 1, true), why)
    end
end)

test('C C11 FORCED MISSING ARGUMENT: a forced parameter the call leaves out gets its nil in place (CART-1506)', function ()
    ready()
    for _, src in ipairs({
        'local function g(a, b, acc)\n  acc = acc or {}\n  acc[1] = a\n  return acc[1] + b\nend\nlocal function f(x, y) return g(x, y) end\n',
        'local function g(a, k, acc)\n  acc = acc or {}\n  acc[1] = a\n  return acc[1] + k()\nend\nlocal function f(x, y) return g(x, function () return y end) end\n',
    }) do
        eq(7, original(src, 'f')(3, 4))
        local r, text = mixed(src, 'f', { 'D', 'D' })
        eq(7, r(3, 4), text)
    end
end)

test('C C12 STATEMENT BINDING TIMES: static and/or, a loop value variable assigned under dynamic control, several-value locals, a static swap, a static call statement (CART-1506)', function ()
    ready()
    local AO = 'local function f(s, x) return s and x end\n'
    eq(7, (mixed(AO, 'f', { 'S', 'D' }, { true }))(7))
    eq(5, (mixed(AO:gsub(' and ', ' or '), 'f', { 'S', 'D' }, { 5 }))(7))
    -- (a static for-in whose value variable is assigned under dynamic control: refused by name — CART-1519 is about
    -- WHICH name — or right; never a residual that does not load)
    for _, body in ipairs({
        '    x = x + v\n    if x > 100 then v = 0 end\n',
        '    if x > 100 then v = 0 end\n    x = x + v\n',
        '    if x > 100 then v, x = 0, 1 end\n',
    }) do
        local src = 'local function f(t, x)\n  for k, v in pairs(t) do\n' .. body .. '  end\n  return x\nend\n'
        local want = original(src, 'f')({ 5 }, 1)
        local why = refusal(src, 'f', { 'S', 'D' }, { { 5 } })
        if why == 'ACCEPTED' then
            local r, text = mixed(src, 'f', { 'S', 'D' }, { { 5 } })
            eq(want, r(1), text)
        else
            ok(not why:find('^NOT A REFUSAL'), why)
        end
    end
    local L4 = 'local function two() return 1, 2 end\nlocal function f(x)\n  local a, b = two()\n  if x then a = 3 b = 4 end\n  return a + b\nend\n'
    local r, text = mixed(L4, 'f', { 'D' })
    eq(7, r(true), text); eq(3, r(false), text)
    local SW = 'local function f(x)\n  local a, b = 1, 2\n  a, b = b, a\n  return a + x\nend\n'
    eq(12, (mixed(SW, 'f', { 'D' }))(10))
    -- (a static call statement still RUNS — its error is raised by the residual; its value is never residualized)
    local E = 'local function g() error("boom") end\nlocal function f(x)\n  g()\n  return x\nend\n'
    local okr, e = pcall((mixed(E, 'f', { 'D' })), 10)
    eq(false, okr); ok(tostring(e):find('boom', 1, true), tostring(e))
    eq(10, (mixed('local function g() return G.h end\nlocal function f(x)\n  g()\n  return x\nend\n', 'f', { 'D' }, {}, { globals = { ['G.h'] = io.stdout } }))(10))
end)

test('C C13 CONTROL FLOW: static if/elseif chains, returns in static branches and do-blocks, unrolled for-ins, repeat, while, break (CART-1506)', function ()
    ready()
    -- (a `while true do end` after a return makes "did not stop at the return" a budget refusal, not a hang)
    for _, c in ipairs({
        { 'local function f(s, x)\n  if s == 1 then x = x + 1 elseif s >= 1 then x = x + 10 else x = x + 100 end\n  return x\nend\n', { 'S', 'D' }, { 1 }, { { 0, 1 } } },
        { 'local function f(s, x)\n  if s then x = x + 1 else return x end\n  while true do end\nend\n', { 'S', 'D' }, { false }, { { 3, 3 } } },
        { 'local function f(t, x)\n  for _, v in ipairs(t) do x = x + v end\n  return x\nend\n', { 'S', 'D' }, { { 1, 2, 3, k = 10 } }, { { 0, 6 } } },
        { 'local function f(t, x)\n  for k in pairs(t) do x = x + k end\n  return x\nend\n', { 'S', 'D' }, { { 5, 6 } }, { { 0, 3 } } },
        { 'local function it(t, i)\n  i = i + 1\n  if t[i] then return i, t[i] end\nend\nlocal function f(t, x)\n  for i, v in it, t, 0 do x = x + v end\n  return x\nend\n', { 'S', 'D' }, { { 10, 20, 30 } }, { { 0, 60 } } },
        { 'local function f(x)\n  local i = 0\n  repeat\n    i = i + 1\n    x = x + i\n  until i >= 3\n  return x\nend\n', { 'D' }, {}, { { 0, 6 } } },
        { 'local function f(x)\n  local n = 0\n  while x > 0 do\n    x = x - 1\n    n = n + 2\n  end\n  return n\nend\n', { 'D' }, {}, { { 3, 6 } } },
        { 'local function f(x)\n  local n = 0\n  for i = 1, 3 do\n    if x == i then break end\n    n = n + i\n  end\n  return n\nend\n', { 'D' }, {}, { { 2, 1 }, { 9, 6 } } },
        { 'local function f(x)\n  local y = x\n  do\n    y = y + 1\n  end\n  return y\nend\n', { 'D' }, {}, { { 3, 4 } } },
        { 'local function f(x)\n  do\n    return x\n  end\n  while true do end\nend\n', { 'D' }, {}, { { 3, 3 } } },
        { 'local function f(x)\n  for i = 1, 5 do\n    x = x + i\n    if i == 2 then break end\n  end\n  return x\nend\n', { 'D' }, {}, { { 0, 3 } } },
        { 'local function f(x)\n  for i = 1, 3 do\n    if i == 2 then return x + i end\n  end\n  while true do end\nend\n', { 'D' }, {}, { { 0, 2 } } },
    }) do
        local src, division, statics = c[1], c[2], c[3]
        local r, text = mixed(src, 'f', division, statics)
        for _, io_ in ipairs(c[4]) do
            local args = {}
            for i, d in ipairs(division) do if d == 'S' then args[i] = statics[i] end end
            args[#division] = io_[1]
            if io_[2] ~= nil and not src:find('while true do end', 1, true) then eq(io_[2], original(src, 'f')(unpack(args, 1, #division))) end
            eq(io_[2], r(io_[1]), text)
        end
    end
end)

test('C C14 LOCATIONS: the source map of a statement spliced from a static if, a refusal\'s where and chain, the root\'s at (CART-1506)', function ()
    ready()
    local src = 'local function f(s, x)\n if s then\n x = x + 1\n end\n return x\nend\n'
    local _, _, _, map = MX.mix(assert(R.read(src, 'lua')), 'f', { 'S', 'D' }, { true })
    eq({ [3] = 3, [4] = 5 }, map)
    local E = 'local function g(a, b) if b == nil then return a end return -1 end\nlocal function f(x) return g(string.upper(x)) end\n'
    local okm, e = pcall(MX.mix, assert(R.read(E, 'lua')), 'f', { 'D' }, {}, { lines = LINES })
    eq(false, okm)
    eq('o.lua:102', type(e) == 'table' and e.where, vim.inspect(e))
    eq({ 'f (o.lua:102)' }, e.chain)
    local at
    local r = mixed(E, 'f', { 'D' }, {}, { lines = LINES, decide = function (kind, ctx) if kind == 'single' then at = ctx.at; return true end end })
    eq('o.lua:102', at)
    eq('AB', r('ab'))
end)

-- ══ D — PRINTER + THE REST ═══════════════════════════════════════════════════════════════════════════════════════════

test('D A lambda arity: a function expression of more than 8 parameters is refused by name (CART-1506)', function ()
    ready()
    refuses('a function expression of more than 8 parameters',
        'local function f(x)\n    local g = function (a, b, c, d, e, f2, g2, h, i) return i end\n    return g(1, 2, 3, 4, 5, 6, 7, 8, x)\nend\n', 'f', { 'D' })
end)

test('D B SRA: a record inside a lambda is replaced; a computed key or a foreign index is not mistaken for a field (CART-1506)', function ()
    ready()
    local src = [[
local function inlam(x, n)
    local function g() local r = { a = n, b = x }; return r.a + r.b end
    return g()
end
local function keyed(x, k) local r = { [k] = x }; return r.a end
local function other(t, n) local r = { a = n }; return r.a + t.b end
]]
    local prog = MX.lower(assert(R.read(src, 'lua')))
    eq(3, prog.sra.candidates); eq(2, prog.sra.replaced)
    local r, text = mixed(src, 'inlam', { 'D', 'S' }, { nil, 5 })
    eq(7, r(2), text)
    ok(not text:find('{', 1, true), 'no table built\n' .. text)
    local rk, tk = mixed(src, 'keyed', { 'D', 'D' })
    eq(7, rk(7, 'a'), tk); eq(nil, rk(7, 'b'), tk)
    local ro, to = mixed(src, 'other', { 'D', 'D' })
    eq(5, ro({ b = 2 }, 3), to)
end)

test('D C assumption kinds: a boolean and a number assumption guard and fold; a table assumption is refused (CART-1506)', function ()
    ready()
    local src = 'local function f(x)\n    if x.big then\n        return 1\n    end\n    return x.n * 2\nend\n'
    local r, text = mixed(src, 'f', { 'D' }, {}, { assume = { big = { value = false } } })
    eq(6, r({ big = false, n = 3 }), text)
    local okr, e = pcall(r, { big = true, n = 3 })
    eq(false, okr, text); eq(DEOPT, e)
    local r2, text2 = mixed(src, 'f', { 'D' }, {}, { assume = { n = { value = 3 } } })
    eq(6, r2({ n = 3 }), text2)
    local okr2, e2 = pcall(r2, { n = 4 })
    eq(false, okr2, text2); eq(DEOPT, e2)
    refuses('an assumption whose value is a table', src, 'f', { 'D' }, {}, { assume = { big = { value = {} } } })
end)

test('D D static operators: / % ~= <= run statically; an operator the evaluator lacks is refused by name (CART-1506)', function ()
    ready()
    local src = 'local function f(x) local a, b, c, d = 7 / 2, 7 % 3, 2 ~= 3, 3 <= 3; return a, b, c, d, x end\n'
    eq({ 3.5, 1, true, true, 1 }, { original(src, 'f')(1) })
    local r, text = mixed(src, 'f', { 'D' })
    eq({ 3.5, 1, true, true, 1 }, { r(1) }, text)
    -- (`//` parses and lowers; the refusal comes from the static evaluator's arith)
    refuses('the operator //', 'local function g(x) return (7 // 2) + x end\n', 'g', { 'D' })
end)

test('D E closure pins: a closure made in a static loop keeps its pinned nil and its unpinned free variable (CART-1506)', function ()
    ready()
    local src = [[
local function f(x, n)
    local base, g = 100, nil
    for i = 1, n do
        local k = nil
        if i > 1 then k = i end
        if i == 1 then g = function (y) if k == nil then return base + y end return k + base + y end end
    end
    return g(x)
end
]]
    eq(105, original(src, 'f')(5, 2))
    local r, text = mixed(src, 'f', { 'D', 'S' }, { nil, 2 })
    eq(105, r(5), text)
end)

test('D F value lists: empty results, a non-last call truncated, missing values nil, one function value is one value (CART-1506)', function ()
    ready()
    local src = [[
local function three() return 1, 2, 3 end
local function g0() return 1 end
local function f(x)
    local g = function () end
    local h = function () return end
    local a, b, c = three(), 10
    local p, q = g0, g0
    return tostring(nil) .. select('#', g()) .. select('#', h()) .. tostring(c) .. tostring(p == q) .. x
end
]]
    eq('nil00niltruex', original(src, 'f')('x'))
    local r, text = mixed(src, 'f', { 'D' })
    eq('nil00niltruex', r('x'), text)
end)

test('D H callf: a closure as a generic-for iterator runs; a table called as one is refused by name (CART-1506)', function ()
    ready()
    local src = 'local function f(x)\n    local it = function (s, i) if i < 3 then return i + 1 end end\n    local s = 0\n    for i in it, nil, 0 do s = s + i end\n    return s + x\nend\n'
    eq(7, original(src, 'f')(1))
    local r, text = mixed(src, 'f', { 'D' })
    eq(7, r(1), text)
    refuses('a call of a table value', 'local function g(x) local t = { 1 }; for v in t do x = x + v end; return x end\n', 'g', { 'D' })
end)

test('D J BTA rank: a closure variable later assigned a dynamic function is dynamic (CART-1506)', function ()
    ready()
    local src = 'local function f(x, h)\n    local g = function (y) return y + x end\n    if x > 0 then g = h end\n    return g(x)\nend\n'
    local h = function (y) return y * 10 end
    local o = original(src, 'f')
    eq(10, o(1, h)); eq(-2, o(-1, h))
    local r, text = mixed(src, 'f', { 'D', 'D' })
    eq(10, r(1, h), text); eq(-2, r(-1, h), text)
end)

test('D K known-global store scan: `error()` with no argument is not a store (CART-1506)', function ()
    ready()
    -- (the triage's second case — a store through `G:items()` — is refused today and pins a limitation: left out)
    local src = 'local function f(x)\n    if x then error() end\n    return 1\nend\n'
    local r, text = mixed(src, 'f', { 'D' })
    eq(1, r(false), text)
    eq(false, (pcall(r, true)))
end)

test('D L static budget: opts.static_budget bounds the static interpreter, refused by name (CART-1506)', function ()
    ready()
    refuses('the interpreter budget (50 steps)',
        'local function sum(n) local s = 0; for i = 1, n do s = s + i end; return s end\nlocal function f(x) return sum(1000) + x end\n',
        'f', { 'D' }, {}, { static_budget = 50 })
end)

test('D M number printing: a non-integer constant prints exactly (CART-1506)', function ()
    ready()
    local src = 'local function f(x) return x * 0.5 end\n'
    eq(1.5, original(src, 'f')(3))
    local r, text = mixed(src, 'f', { 'D' })
    eq(1.5, r(3), text)
end)

test('D N statement printing: a method call, a call of a program function and a bare expression call print as statements; long bodies; an empty several-value local (CART-1506)', function ()
    ready()
    local src = [[
local function id(a) return a end
local function inc(a) return a + 1 end
local function f(t, x)
    local y = x + 1
    t:add(y)
    inc(x)
    id(x)
    return y
end
]]
    local T = { n = 0 }
    function T.add(self, v) self.n = self.n + v end
    local r, text = mixed(src, 'f', { 'D', 'D' })
    eq(3, r(T, 2), text); eq(3, T.n, text)
    local big = 'local function f(t, x)\n' .. string.rep('    table.insert(t, x)\n', 210) .. '    return #t\nend\n'
    eq(210, (mixed(big, 'f', { 'D', 'D' }))({}, 1))
    local src3 = 'local function none() end\nlocal function f(x)\n    local a, b = none()\n    if x > 0 then a = x; b = x end\n    return a, b\nend\n'
    local r3, text3 = mixed(src3, 'f', { 'D' })
    eq({ 2, 2 }, { r3(2) }, text3)
    local n = select('#', r3(-1))
    eq({ 2, nil, nil }, { n, r3(-1) }, text3)
end)

test('D O API edges: MX.run of a missing function, describe, translate (CART-1506)', function ()
    ready()
    local okr, e = pcall(MX.run, MX.lower(assert(R.read('local function f(x) return x end', 'lua'))), 'nope', {})
    eq(false, okr); eq('no function nope', type(e) == 'table' and e.refusal)
    eq('boom', MX.describe('boom'))
    eq('L', MX.describe({ lazy = 'L' }))
    local t = {}
    eq(t, MX.translate(t, { [1] = 'src:9' }))
    eq('[string "r"]:2: boom', MX.translate('[string "r"]:2: boom', nil))
    eq('[string "r"]:7: boom', MX.translate('[string "r"]:7: boom', { [2] = 'src:9' }))
end)

test('D Q forward declaration: the residual declares its functions local, it writes no global (CART-1506)', function ()
    ready()
    local src = 'local function g(a) if a > 0 then return g(a - 1) end return 0 end\nlocal function f(x) return g(x) end\n'
    eq(0, original(src, 'f')(3))
    local r, text, _, env = mixed(src, 'f', { 'D' })
    eq(0, r(3), text)
    local leaked = {}
    for k in pairs(env) do if k ~= 'MIXK' and k ~= 'MIXDEOPT' then leaked[#leaked + 1] = k end end
    eq({}, leaked, text)
end)

-- ══ FILED BUGS — the correct behaviour; SKIPPED with the ticket while it is open (only on its documented symptom) ═════

test('BUG CART-1509: a store through a call result `id(t).x = d` reaches t (CART-1506)', function ()
    ready()
    local src = 'local function id(t) return t end\nlocal function f(d)\n  local t = {}\n  id(t).x = d\n  return t.x\nend\n'
    eq(5, original(src, 'f')(5))
    -- (FIXED as a REFUSAL BY NAME: the table a call's result names is unknown to the analysis — it folded t.x to nil)
    refuses('a store into a table reached through id(t)', src, 'f', { 'D' })
    -- (a parenthesized base is its variable, and stores into it)
    local src2 = 'local function f(d)\n  local t = {}\n  (t).x = d\n  return t.x\nend\n'
    eq(5, mixed(src2, 'f', { 'D' })(5))
end)

test('BUG CART-1510: SRA keeps the forcing of a mutated record — `table.insert(s.items, d)` (CART-1506)', function ()
    ready()
    local src = 'local function f(d)\n  local s = { items = {} }\n  table.insert(s.items, d)\n  return #s.items\nend\n'
    eq(1, original(src, 'f')(10))
    local r, text = mixed(src, 'f', { 'D' })
    local got = r(10)
    -- (CART-1510 fixed: a forced record is not split — a 0 is a regression, not a skip)
    eq(1, got, text)
end)

test('BUG CART-1511: a host call keeps its trailing nils — `v(x, nil)` passes 1 extra value (CART-1506)', function ()
    ready()
    local src = 'local function v(a, ...) return select("#", ...) end\nlocal function f(x) return v(x, nil) end\n'
    eq(1, original(src, 'f')(1))
    local r, text = mixed(src, 'f', { 'D' })
    local got = r(1)
    -- (CART-1511 fixed: host results are counted with their trailing nils — a 0 is a regression, not a skip)
    eq(1, got, text)
end)

test('BUG CART-1512: a multi-assignment to a call\'s field `mk().k, y = x, x` prints a residual that loads (CART-1506)', function ()
    ready()
    local src = 'local function mk() return {} end\nlocal function f(x)\n    local y\n    mk().k, y = x, x\n    return y\nend\n'
    eq(3, original(src, 'f')(3))
    -- (FIXED with CART-1509: a target reached through a call is refused by name at lowering — never a residual that
    -- does not load)
    refuses('a store into a table reached through mk()', src, 'f', { 'D' })
end)

test('BUG CART-1513: -0 prints as -0 — `x / (0 * -1)` is -inf (CART-1506)', function ()
    ready()
    local src = 'local function f(x) return x / (0 * -1) end\n'
    eq(-math.huge, original(src, 'f')(3))
    local r, text = mixed(src, 'f', { 'D' })
    local got = r(3)
    -- (CART-1513 fixed: the printer spells -0 — an inf is a regression, not a skip)
    eq(-math.huge, got, text)
end)

test('BUG CART-1514: an assumed math.huge guards with a real infinity, not a bare `inf` global (CART-1506)', function ()
    ready()
    local src = 'local function f(x)\n    if x.n > 5 then return 1 end\n    return 0\nend\n'
    eq(1, original(src, 'f')({ n = math.huge }))
    local r, text = mixed(src, 'f', { 'D' }, {}, { assume = { n = { value = math.huge } } })
    local okr, got = pcall(r, { n = math.huge })
    -- (CART-1514 fixed: the printer spells an assumed inf — a deopt is a regression, not a skip)
    eq(true, okr, tostring(got)); eq(1, got, text)
    -- (n missing: the original raises, the residual raises or deoptimizes — never returns)
    eq(false, (pcall(r, {})), text)
end)

test('BUG CART-1515: an error a static pcall catches carries no mix.lua line — level 2 under a line map is Lua\'s `bad 7` (CART-1506)', function ()
    ready()
    local lines = {}
    for n = 1, 20 do lines[n] = { src = 'orig.lua', line = 100 + n } end
    local src = 'local function bad(x)\n    error("bad " .. x, 2)\nend\nlocal function f(x, d)\n    local ok, why = pcall(bad, x)\n    return why .. d\nend\n'
    -- (level 2 names bad's caller, which is pcall — a C function: no position)
    eq('bad 7!', original(src, 'f')(7, '!'))
    local r, text = mixed(src, 'f', { 'S', 'D' }, { 7 }, { lines = lines })
    local got = r('!')
    if got:find('mix.lua', 1, true) then skip('CART-1515 open: eval_multi maps level nil/1 only, level 2 raises from mix.lua\'s own frame') end
    eq('bad 7!', got, text)
    -- (no line map: whatever the position, never mix.lua's own)
    local src2 = 'local function bad(x)\n    error("bad " .. x)\nend\nlocal function f(x, d)\n    local ok, why = pcall(bad, x)\n    return why .. d\nend\n'
    local r2, text2 = mixed(src2, 'f', { 'S', 'D' }, { 7 })
    ok(not r2('!'):find('mix.lua', 1, true), text2)
end)

test('BUG CART-1517: a lambda lifted inside itself binds fresh names — the inner `v` does not capture the outer one (CART-1506)', function ()
    ready()
    local src = [[
local function wrap(k, n)
  if n == 0 then return k end
  return function (v) return wrap(function () return k() + v end, n - 1) end
end
local function f(x)
  local g = wrap(function () return x end, 2)
  return g
end
]]
    eq(111, original(src, 'f')(1)(10)(100)())
    local r, text = mixed(src, 'f', { 'D' })
    local got = r(1)(10)(100)()
    -- (CART-1517 fixed: a lifted lambda's binders carry the lift's suffix — a 201 is a regression, not a skip)
    eq(111, got, text)
end)
