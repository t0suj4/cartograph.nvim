-- The effects fixpoint: transitive write summaries in ONE reverse-topo
-- pass over the SCC condensation, gp discharged at the inheriting call
-- site, pw propagated through argument targets, hedges never silently
-- dropped. Plus the consumers: purity labels and calls_commute.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local effects = require 'cartograph.effects'
local scc = require 'cartograph.scc'

local function ready()
    return pcall(vim.treesitter.language.add, 'lua')
end

local function mkroot(src)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(src)
    fd:close()
    return root
end

test('scc: condensation, emission order, recursion fact', function ()
    -- a -> b <-> c -> d ; e isolated
    local adj = { a = { 'b' }, b = { 'c' }, c = { 'b', 'd' }, d = {}, e = {} }
    local r = scc.condense(adj, { 'a', 'b', 'c', 'd', 'e' })
    ok(r.comp.b == r.comp.c, 'the mutual pair is one component')
    ok(r.comp.a ~= r.comp.b and r.comp.d ~= r.comp.b, 'others separate')
    ok(r.comp.d < r.comp.b and r.comp.b < r.comp.a,
        'emission order is callees-first (reverse topological)')
end)

local SRC = table.concat({
    'local state = {}',
    'local buf = {}',
    'local flags = {}',
    'local function leaf() state.x = 1 end',            -- direct write
    'local function mid() leaf() end',                  -- inherits
    'local function top() mid() end',                   -- transitively
    'local function clean(a, b) return a + b end',      -- pure
    'local function condw(flush) if flush then buf.n = 1 end end', -- gp
    'local function caller_off() condw(false) end',     -- discharged: skips
    'local function caller_on() condw(true) end',       -- inherits guarded
    'local function mut(t) t.k = 1 end',                -- pw
    'local function feeds() mut(state) end',            -- pw -> var write
    'local function relay(q) mut(q) end',               -- pw -> own param
    'local function builtin_hit() table.insert(buf, 1) end', -- builtin
    'local function mystery() UNKNOWN_FN(1) end',       -- hedge
    'local Mx = {}',                                     -- mutual recursion
    'function Mx.ra() return Mx.rb() end',               -- (module-table style:
    'function Mx.rb() state.y = 2 return Mx.ra() end',   -- forward-declared
                                                         -- locals resolve to
                                                         -- NOTHING, silently —
                                                         -- a filed resolver gap)
    'local function once() if not flags.f then flags.f = true end end',
    'local function twice() once() once() end',
    'return { leaf, mid, top, clean, condw, caller_off, caller_on, mut,',
    '    feeds, relay, builtin_hit, mystery, Mx, once, twice }',
}, '\n')

local function byname()
    local out = {}
    for _, n in ipairs(store.data.nodes) do out[n.name] = n end
    return out
end

test('fixpoint: transitive writes, discharge, pw, builtins, hedges', function ()
    if not ready() then skip 'no lua parser' end
    store.ingest(ts.extract(mkroot(SRC)))
    local by = byname()
    local sums = effects.summaries(store)
    local skey = by.state.id .. '\31x'
    ok(sums[by.leaf.id].w[skey], 'direct write recorded per field')
    ok(sums[by.mid.id].w[skey], 'one hop inherited')
    ok(sums[by.top.id].w[skey], 'two hops inherited')
    eq('pure', effects.purity(store, by.clean.id), 'clean is PURE')
    eq('writes', effects.purity(store, by.top.id))
    -- gp discharge at the inheriting site
    local bkey = by.buf.id .. '\31'
    ok(sums[by.condw.id].w[bkey] and sums[by.condw.id].gpk[bkey],
        'the conditional writer carries a dischargeable key')
    eq(nil, sums[by.caller_off.id].w[bkey], 'flush=false: write NOT inherited')
    eq('pure', effects.purity(store, by.caller_off.id),
        'a fully discharged caller is PURE')
    ok(sums[by.caller_on.id].w[bkey], 'flush=true: inherited')
    -- pw propagation through argument targets
    ok(sums[by.mut.id].pwx and sums[by.mut.id].pwx[1], 'mut mutates param 1')
    ok(sums[by.feeds.id].w[by.state.id .. '\31'],
        'passing a module var into a param-mutator writes the var')
    ok(sums[by.relay.id].pwx and sums[by.relay.id].pwx[1],
        'passing OWN param onward extends transitive pw')
    -- builtins
    ok(sums[by.builtin_hit.id].w[by.buf.id .. '\31'],
        'table.insert(buf, 1) writes buf via the builtin table')
    -- hedges
    eq('pure~', effects.purity(store, by.mystery.id),
        'an unresolved call hedges, never silently pure')
    -- mutual recursion: shared summary, single pass
    local ykey = by.state.id .. '\31y'
    ok(sums[by['Mx.ra'].id].w[ykey] and sums[by['Mx.rb'].id].w[ykey],
        'the SCC pair shares the write')
    ok(sums[by['Mx.ra'].id] == sums[by['Mx.rb'].id], 'literally one summary')
end)

test('fixpoint: calls_commute — conflict, set-once excuse, honesty', function ()
    if not ready() then skip 'no lua parser' end
    store.ingest(ts.extract(mkroot(SRC)))
    local by = byname()
    local calls = {}
    for _, c in ipairs(store.data.calls) do
        if c.to then calls[#calls + 1] = c end
    end
    local function callto(name)
        for _, c in ipairs(calls) do
            if c.to == by[name].id then return c end
        end
    end
    local v1, why1 = effects.calls_commute(store, callto('leaf'), callto('Mx.rb'))
    eq('commute', v1, why1) -- state.x vs state.y: different fields
    local v2 = effects.calls_commute(store, callto('leaf'), callto('leaf'))
    eq('conflict', v2, 'same unguarded write conflicts')
    local v3, why3 = effects.calls_commute(store, callto('once'), callto('once'))
    eq('commute', v3, 'set-once writes to the same key commute: ' .. (why3 or ''))
    local v4 = effects.calls_commute(store, callto('mystery'), callto('leaf'))
    eq('unknown', v4, 'a hedged summary never claims commute')
end)

test('signatures: packs un-hedge, io orders, higher-order inherits', function ()
    if not ready() then skip 'no lua parser' end
    store.ingest(ts.extract(mkroot(table.concat({
        'local acc = {}',
        'local function calc(x) return math.floor(x) + #tostring(x) end',
        'local function methodpure(s) return s:gsub("a", "b") end',
        'local function noisy(m) print(m) end',
        'local function noisy2() vim.api.nvim_echo() end',
        'local function rolled() return math.random() end',
        'local function writer() acc.n = 1 end',
        'local function guarded() pcall(writer) end',      -- higher-order
        'local function guarded2() pcall(function() end) end', -- anonymous
        'local function asserted_call() MYAPI_poke() end',
        'return { calc, methodpure, noisy, noisy2, rolled, writer,',
        '    guarded, guarded2, asserted_call }',
    }, '\n'))))
    local by = byname()
    local sums = effects.summaries(store)
    eq('pure', effects.purity(store, by.calc.id),
        'stdlib pack: math.floor/tostring/# no longer hedge')
    eq('pure~', effects.purity(store, by.methodpure.id),
        'method tier is name-matched: pure, but ~')
    eq('io', effects.purity(store, by.noisy.id), 'print writes the world')
    eq('io', effects.purity(store, by.noisy2.id), 'vim.api.* prefix: world')
    eq('pure', effects.purity(store, by.rolled.id),
        'math.random: effect-free — nondet rides a flag, not a hedge')
    ok(sums[by.rolled.id].nd, '...and the flag is set')
    -- higher-order: pcall(writer) costs what writer costs
    ok(sums[by.guarded.id].w[by.acc.id .. '\31n'],
        'pcall(writer) inherits the write through calls={1}')
    eq('writes', effects.purity(store, by.guarded.id))
    -- ★ A CORRECTION I OWE THIS TEST (CART-0813). I flipped it to `pure`, on the
    -- reasoning that a lua inline closure is a node now so its effects are known.
    -- The flip was real and the REASON was wrong: it passed because the ownership
    -- defect fixed alongside — `fn_at` was line-granular, so `pcall(function() end)`
    -- was attributed to the closure it passes — had left `guarded2` with NO CALLS
    -- AT ALL. Trivially pure, for a reason that has nothing to do with callbacks.
    -- With ownership correct the hedge is back, and it is still honest: the node
    -- exists and `argv.to` now points at it, but the effects fixpoint's
    -- higher-order path resolves a NAMED callee and does not yet read a `func`
    -- argument's target. That is a real follow-on, not a thing to assert away.
    -- ★ AND THE FOLLOW-ON, CORRECTED (CART-1494): the fixpoint DID read `argv.to` — the miss was ORDER. The callback
    -- is no call edge of `guarded2`, so the condensation (ids sorted: `guarded2` < `pcall#cb`) summarized guarded2
    -- first and found no summary to inherit. The callback is now a successor of its enclosing function, and the
    -- empty closure's effects (none) are guarded2's: pure, for the callback's reason this time.
    eq('pure', effects.purity(store, by.guarded2.id),
        'pcall(anonymous): the callback node is summarized first, and it does nothing')
    -- io-io ordering conflict through commute
    local c1, c2
    for _, c in ipairs(store.data.calls) do
        if c.to == by.noisy.id then c1 = c end
        if c.to == by.noisy2.id then c2 = c end
    end
    if c1 and c2 then
        local v, why = effects.calls_commute(store, c1, c2)
        eq('conflict', v, 'two world-writers do not commute: ' .. (why or ''))
    end
end)

test('signatures: asserted tier applies AND hedges with the name', function ()
    if not ready() then skip 'no lua parser' end
    local config = require 'cartograph.config'
    local saved = config.effects
    config.effects = { MYAPI_poke = { io = true } }
    store.ingest(ts.extract(mkroot(table.concat({
        'local function asserted_call() MYAPI_poke() end',
        'return { asserted_call }',
    }, '\n'))))
    local by = byname()
    local sum = effects.summaries(store)[by.asserted_call.id]
    config.effects = saved
    ok(sum.w['\1io\31'], 'the asserted io contract is APPLIED')
    ok(sum.h and sum.h[1]:find('asserted contract: MYAPI_poke', 1, true),
        'and every use is hedged with the assertion named')
    -- label: io~ — conditional on the user being right, visibly
end)

test('fixpoint: a FRESH local sorted with an INLINE comparator is the call\'s own business — pure; a local read from a parameter is not fresh (CART-1494)', function ()
    if not ready() then skip 'no lua parser' end
    store.ingest(ts.extract(mkroot(table.concat({
        -- (named to sort BEFORE the minted `sort#cb` node: the condensation must still summarize the callback first)
        'local function a_sorted(t) local out = {} for k in pairs(t) do out[#out + 1] = k end table.sort(out, function (x, y) return x < y end) return out end',
        'local function b_alias(t) local out = t.list table.sort(out) return out end',
        'return { a_sorted, b_alias }' }, '\n'))))
    local by = byname()
    eq('pure', effects.purity(store, by.a_sorted.id), 'a table this call made, sorted by a pure inline comparator')
    eq('pure~', effects.purity(store, by.b_alias.id), 'a local bound to a parameter\'s field may alias the caller\'s table')
end)

test('fixpoint: a call through a PARAMETER is substituted at each call to its owner — a CPS walker handed pure continuations is pure; handed a writing one, it writes; left unsubstituted, it is hedged (CART-1495)', function ()
    if not ready() then skip 'no lua parser' end
    store.ingest(ts.extract(mkroot(table.concat({
        'local log = {}',
        -- (CPS: the walker calls its continuation, and recurses handing on a closure that calls the outer one)
        'local function walk(t, k) if not t then return k(0) end return walk(t.next, function (n) return k(n + 1) end) end',
        'local function count(t) return walk(t, function (n) return n end) end',
        'local function noisy(t) return walk(t, function (n) log[#log + 1] = n; return n end) end',
        'local function apply(f, x) return f(x) end',
        -- (a continuation that RE-ENTERS the walker: the closure is in the walker's own component, as the matcher's are)
        'local function seq(l, i, k) if i > #l then return k() end return seq(l, i + 1, function () return seq(l, #l + 1, k) end) end',
        'local function done(l) return seq(l, 1, function () return true end) end',
        'return { count, noisy, apply, done }' }, '\n'))))
    local by = byname()
    eq('pure', effects.purity(store, by.count.id), 'every continuation it can reach is pure')
    eq('writes', effects.purity(store, by.noisy.id), 'the continuation it hands in writes `log`')
    eq('pure~', effects.purity(store, by.apply.id), 'calls what it is handed: as pure as that')
    eq('pure', effects.purity(store, by.done.id), 'a continuation inside the walker\'s component is the component\'s own')
end)

test('fixpoint: REBINDING a parameter (`t = t.kids[i]`) is no write through it — only a store INTO it (`t.x = 1`, `t[k] = 1`) mutates the caller\'s table', function ()
    if not ready() then skip 'no lua parser' end
    store.ingest(ts.extract(mkroot(table.concat({
        'local function walk(t, path) for _, i in ipairs(path) do t = t.kids[i] end return t end',
        'local function poke(t) t.x = 1 end',
        'local function poke2(t, k) t[k] = 1 end',
        'return { walk, poke, poke2 }' }, '\n'))))
    local by = byname()
    eq('pure', effects.purity(store, by.walk.id), 'a rebound parameter is a local')
    eq('writes', effects.purity(store, by.poke.id), 'a field store into a parameter')
    eq('writes', effects.purity(store, by.poke2.id), 'an index store into a parameter')
end)

local AMB = {
    'local log = {}',
    'local A, B, C, D = {}, {}, {}, {}',
    'function A:go() return 1 end',
    'function B:go() log.n = 1 end',
    'function C:peek() return 1 end',
    'function D:peek() return 2 end',
    'local function either(o) return o:go() end',   -- ambiguous: A:go, B:go
    'local function quiet(o) return o:peek() end',  -- ambiguous: C:peek, D:peek
    'local function relay(o) return quiet(o) end',  -- resolved, onto a joined summary
    'local function first(s) return s:gsub("a", "b") end', -- the method~ tier
    'local function second(s) return first(s) end', -- resolved, onto it
    'local function viacb(o) return pcall(function () return o:peek() end) end', -- a CALLBACK onto a join (CART-1558)
    'local function apply(f, x) return f(x) end',
    'local function viasub(o) return apply(function () return o:peek() end, 1) end', -- a SUBSTITUTED pair onto a join
}
for i = 1, 9 do AMB[#AMB + 1] = ('local T%d = {} function T%d:many() return %d end'):format(i, i, i) end
AMB[#AMB + 1] = 'local function crowd(o) return o:many() end' -- 9 candidates: the refusal keeps 8, the list is not whole
AMB[#AMB + 1] = 'return { either, quiet, relay, second, crowd, viacb, viasub }'

test('fixpoint: an AMBIGUOUS call is the JOIN of its candidates — a candidate\'s write is the call\'s, an all-pure join stays ~ under its premise, a cut list keeps the hedge; the tiers travel through a resolved call', function ()
    if not ready() then skip 'no lua parser' end
    store.ingest(ts.extract(mkroot(table.concat(AMB, '\n'))))
    local by = byname()
    local sums = effects.summaries(store)
    eq('writes~', effects.purity(store, by.either.id), 'B:go writes log: the call may')
    ok(sums[by.either.id].w[by.log.id .. '\31n'], 'the write is log.n')
    eq('pure~', effects.purity(store, by.quiet.id), 'every candidate pure: pure under the premise, never plain pure')
    eq(nil, sums[by.quiet.id].h, 'no hedge: the premise is what is left')
    eq(true, sums[by.quiet.id].jp)
    eq('pure~', effects.purity(store, by.relay.id), 'the premise travels through a resolved call')
    eq('pure~', effects.purity(store, by.second.id), 'and so does the method~ tier')
    eq('pure~', effects.purity(store, by.viacb.id), 'through a callback (CART-1558)')
    eq('pure~', effects.purity(store, by.viasub.id), 'through a substituted pending pair (CART-1558)')
    for _, x in ipairs(store.data.calls) do
        if x.to == by.quiet.id then
            local slice = effects.call_effects(store, x)
            ok(slice.hedges and vim.tbl_contains(slice.hedges, 'an ambiguous call joined over its candidates'), 'a call slice carries the premise: ' .. vim.inspect(slice.hedges))
        end
    end
    for _, x in ipairs(store.data.calls) do
        if x.to == by.first.id then eq('unknown', (effects.calls_commute(store, x, x)), 'nor does commute decide on the method~ tier (CART-1546)') end
    end
    ok(sums[by.crowd.id].h and sums[by.crowd.id].h[1]:find('refused (ambiguous)', 1, true), 'a cut candidate list keeps the hedge')
    eq(nil, sums[by.crowd.id].jp)
    -- (commute on the premise: not decided)
    local c
    for _, x in ipairs(store.data.calls) do if x.to == by.quiet.id then c = x end end
    local v, why = effects.calls_commute(store, c, c)
    eq('unknown', v, why)
    -- the other side: the join off, the hedge is back and the write is not found
    effects.JOIN.ambiguous = nil
    store._fx = nil
    local ok2, err = pcall(function ()
        local off = effects.summaries(store)
        ok(off[by.quiet.id].h and off[by.quiet.id].h[1]:find('refused (ambiguous)', 1, true), 'hedged without the join')
        eq(nil, off[by.either.id].w[by.log.id .. '\31n'], 'and the write is not seen')
    end)
    effects.JOIN.ambiguous = true
    store._fx = nil
    assert(ok2, err)
end)

test('fixpoint: a TABLE CONSTRUCTOR argument is fresh — setmetatable({}, mt) writes nothing outside; a table that came from elsewhere still hedges (CART-1547)', function ()
    if not ready() then skip 'no lua parser' end
    store.ingest(ts.extract(mkroot(table.concat({
        'local mt = { __index = {} }',
        'local function mk() return setmetatable({}, mt) end',
        'local function mk2() return setmetatable({ n = 1 }, mt) end',
        'local function wrap(f) return setmetatable(f(), mt) end',
        'return { mk, mk2, wrap }' }, '\n'))))
    local by = byname()
    eq('pure', effects.purity(store, by.mk.id), 'an empty constructor')
    eq('pure', effects.purity(store, by.mk2.id), 'a constructor with fields')
    local h = effects.summaries(store)[by.wrap.id].h
    ok(h and h[1]:find('setmetatable on opaque arg', 1, true), 'a call result may be anyone\'s table: ' .. vim.inspect(h))
end)

test('fixpoint: an OVERFLOWED write set keeps no keys — which 200 survived would depend on arrival order (CART-1545) — and a caller inheriting it drops the keys it had made itself', function ()
    if not ready() then skip 'no lua parser' end
    local src = { 'local S, T = {}, {}', 'local function many()' }
    for i = 1, 201 do src[#src + 1] = ('    S.f%d = 1'):format(i) end
    src[#src + 1] = 'end'
    src[#src + 1] = 'local function caller() T.own = 1; many() end'
    src[#src + 1] = 'return { many, caller }'
    store.ingest(ts.extract(mkroot(table.concat(src, '\n'))))
    local by = byname()
    local sums = effects.summaries(store)
    eq(true, sums[by.many.id].over)
    eq({}, sums[by.many.id].w, 'no surviving keys')
    eq('writes~', effects.purity(store, by.many.id), 'still many writes')
    eq(true, sums[by.caller.id].over)
    eq({}, sums[by.caller.id].w, 'its own T.own went with the overflow')
end)

test('fixpoint: a join whose candidate is summarized LATER repeats the pass to the fixpoint, and a later pass recomputes only what read a changed summary (CART-1544)', function ()
    if not ready() then skip 'no lua parser' end
    store.ingest(ts.extract(mkroot(table.concat({
        'local log = {}',
        'local A1, B1, B2, C1, C2, K1, K2 = {}, {}, {}, {}, {}, {}, {}',
        -- (each call ambiguous, each candidate summarized AFTER its caller: no call edge orders a join)
        'function A1:go(o) return o:mid() end',
        'function B1:mid(o) return o:fin() end',
        'function B2:mid() return 1 end',
        'function C1:fin() log.n = 1 end',
        'function C2:fin() return 2 end',
        'function A1:steady(o) return o:calm() end',      -- recomputed in pass 2, to the SAME summary
        'function K1:calm() return 1 end',
        'function K2:calm() return 2 end',
        'local function y(o) return A1.steady(A1, o) end', -- reads only that: reused
        'return { A1, B1, B2, C1, C2, K1, K2, y }' }, '\n'))))
    local by = {}
    for _, n in ipairs(store.data.nodes) do local k = n.id:match('::(.-)@'); if k then by[k] = n end end
    eq('writes~', effects.purity(store, by['A1:go'].id), 'C1:fin writes log, two ambiguous hops and two passes away')
    eq('pure~', effects.purity(store, by.y.id))
    local js = effects.join_stats
    eq(4, js.rounds, 'B1:mid changes in pass 2, A1:go in pass 3, pass 4 changes nothing')
    -- pass 1 all 9; pass 2 the three joins (A1:go, B1:mid, A1:steady — y reads A1:steady, unchanged, so y is reused);
    -- pass 3 A1:go alone (B1:mid changed); pass 4 nothing
    eq(13, js.computed, 'only what read a changed summary is recomputed')
end)
