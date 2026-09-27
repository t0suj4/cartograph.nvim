-- LIFT -> SPECIALIZE -> LOWER (lua/cartograph/qlower.lua, CART-1142 S5b): Lua to a trivia-stripped term and back,
-- constant folding under STATED facts, and the scope the folds must keep.

local function need() if not parser_available('lua') then skip 'no lua parser' end end

local function run(src) return assert(load(src))() end

test('qlower: lift then lower is valid Lua that computes the same — comments go, string literals stay verbatim', function ()
    need()
    local QL = require 'cartograph.qlower'
    local src = 'local s = "a  b -- not a comment" -- zzqq\nlocal t = { x = 1 } ; return s .. t.x .. [[ c  d ]] .. #("   ")\n'
    local out = QL.lower(assert(QL.lift(src)))
    eq(run(src), run(out))
    ok(not out:find('zzqq', 1, true), out)
    ok(out:find('"a  b -- not a comment"', 1, true), out)
end)

test('qlower.specialize: a fold fires only under its stated fact, and an unknown name is left alone', function ()
    need()
    local QL = require 'cartograph.qlower'
    local src = 'local function f(t, m, q)\n  local v = 1\n  if t then v = t(v) end\n  if not m or m[q] then v = v + 1 end\n  return v\nend\nreturn f\n'
    local T = assert(QL.lift(src))
    local s1, log1 = QL.specialize(T, QL.fold_laws(), { t = 'nil', m = 'nil' })
    local fired = {}
    for _, l in ipairs(log1) do fired[#fired + 1] = l.law end
    eq({ 'if-nil drops', 'not-nil or' }, fired)
    eq(2, run(QL.lower(s1))(nil, nil, 1))
    local _, log2 = QL.specialize(T, QL.fold_laws(), {})
    eq(0, #log2, 'no facts, no folds')
end)

test('qlower: a kept branch keeps its SCOPE — a local it declares does not leak over an outer one', function ()
    need()
    local QL = require 'cartograph.qlower'
    local src = 'local s = true\nlocal x = 1\nif s then local x = 2 end\nreturn x\n'
    local spec = QL.specialize(assert(QL.lift(src)), QL.fold_laws(), { s = 'set' })
    local out = QL.lower(spec)
    ok(out:find(' do ', 1, true), out)
    eq(1, run(out))
end)

test('qlower.find_function finds a local function declaration by name, and the lowered kernel of solve.lua loads', function ()
    need()
    local QL = require 'cartograph.qlower'
    local solve = require 'cartograph.solve'
    local fd = assert(io.open(solve.source_path())); local src = fd:read('a'); fd:close()
    local _, fn = QL.find_function(assert(QL.lift(src)), 'run_worklist')
    ok(fn, 'run_worklist found')
    local k = assert(load(QL.lower(fn) .. ' return run_worklist'))()
    local B = solve.lattice.bitset(1)
    local r = solve.solve { nodes = { 'a', 'b' }, succ = { a = { 'b' }, b = {} }, lattice = B, kernel = k,
        init = function (id) return id == 'a' and B.single(1) or nil end }
    eq({ 1 }, B.members(r.value.b))
end)
