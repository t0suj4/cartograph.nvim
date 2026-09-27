-- THE SHARED SOLVER (lua/cartograph/solve.lua, CART-1037 / CART-1142): strategies agree, directions, convergence as a
-- returned field, the in-place path against a plain lattice.

local solve = require 'cartograph.solve'

-- a graph with a cycle (b <-> c), a diamond (a -> b, a -> d, d -> c) and an unreached node (z)
local NODES = { 'a', 'b', 'c', 'd', 'e', 'z' }
local SUCC = { a = { 'b', 'd' }, b = { 'c' }, c = { 'b', 'e' }, d = { 'c' }, e = {}, z = { 'e' } }

-- a plain set lattice with no in-place form: the solver's generic path
local function setlattice()
    local L = { props = { join = { commutative = true, associative = true, idempotent = true } } }
    function L.bottom() return {} end
    function L.join(x, y) local s = {}; for k in pairs(x) do s[k] = true end; for k in pairs(y) do s[k] = true end; return s end
    function L.eq(x, y) for k in pairs(x) do if not y[k] then return false end end; for k in pairs(y) do if not x[k] then return false end end; return true end
    return L
end
local function show(value, members)
    local out = {}
    for _, id in ipairs(NODES) do
        local v = value[id]
        local ms = v and members(v) or {}
        table.sort(ms)
        out[#out + 1] = id .. '=' .. table.concat(ms, '')
    end
    return table.concat(out, ' ')
end

test('solve: forward reachability from seeds — worklist, scc, the bitset and the plain lattice all agree', function ()
    local seeds = { 'a', 'z' }
    local B = solve.lattice.bitset(#seeds)
    local idx = { a = 1, z = 2 }
    local names = { 'a', 'z' }
    local function bits(v) local out = {}; for _, i in ipairs(B.members(v)) do out[#out + 1] = names[i] end; return out end
    local want = 'a=a b=a c=a d=a e=az z=z'
    for _, strat in ipairs { 'worklist', 'scc' } do
        local r = solve.solve { nodes = NODES, succ = SUCC, lattice = B, strategy = strat,
            init = function (id) return idx[id] and B.single(idx[id]) or nil end }
        eq(want, show(r.value, bits), strat)
        ok(r.converged, strat)
        local P = setlattice()
        local rp = solve.solve { nodes = NODES, succ = SUCC, lattice = P, strategy = strat,
            init = function (id) return idx[id] and { [id] = true } or nil end }
        eq(want, show(rp.value, function (v) local o = {}; for k in pairs(v) do o[#o + 1] = k end; return o end), strat .. ' plain')
    end
end)

test('solve: backward — each node learns the seeds it reaches; the scc strategy visits fewer nodes than the worklist', function ()
    local B = solve.lattice.bitset(1)
    local r = solve.solve { nodes = NODES, succ = SUCC, lattice = B, direction = 'backward', strategy = 'scc',
        init = function (id) return id == 'e' and B.single(1) or nil end }
    eq('a=1 b=1 c=1 d=1 e=1 z=1', show(r.value, B.members))
    local w = solve.solve { nodes = NODES, succ = SUCC, lattice = B, direction = 'backward', strategy = 'worklist',
        init = function (id) return id == 'e' and B.single(1) or nil end }
    eq(show(r.value, B.members), show(w.value, B.members))
    ok(r.visits <= w.visits, ('scc %d visits, worklist %d'):format(r.visits, w.visits))
end)

test('solve: a visit limit returns converged = false, never a silent partial answer', function ()
    local B = solve.lattice.bitset(1)
    local r = solve.solve { nodes = NODES, succ = SUCC, lattice = B, strategy = 'worklist', limit = 2,
        init = function (id) return id == 'a' and B.single(1) or nil end }
    eq(false, r.converged)
    eq(2, r.visits)
end)

test('solve: the in-place join never hands out its scratch buffer — two nodes with different values stay different', function ()
    -- b and d each join two seeds' values: a result aliased to the shared scratch would make them equal
    local nodes = { 's1', 's2', 's3', 'b', 'd' }
    local succ = { s1 = { 'b' }, s2 = { 'b', 'd' }, s3 = { 'd' }, b = {}, d = {} }
    local B = solve.lattice.bitset(3)
    local idx = { s1 = 1, s2 = 2, s3 = 3 }
    local r = solve.solve { nodes = nodes, succ = succ, lattice = B, init = function (id) return idx[id] and B.single(idx[id]) or nil end }
    eq('1,2', table.concat(B.members(r.value.b), ','))
    eq('2,3', table.concat(B.members(r.value.d), ','))
end)

test('solve.lattice.bitset: leq, count and members over word boundaries', function ()
    local B = solve.lattice.bitset(70)
    local x = B.join(B.single(1), B.single(33))
    x = B.join(x, B.single(70))
    eq({ 1, 33, 70 }, B.members(x))
    eq(3, B.count(x))
    ok(B.leq(B.single(33), x))
    ok(not B.leq(x, B.single(33)))
    ok(B.eq(B.join(x, B.single(33)), x))
end)
