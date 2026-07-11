-- The effects fixpoint: transitive write summaries in ONE reverse-topo
-- pass over the SCC condensation, gp discharged at the inheriting call
-- site, pw propagated through argument targets, hedges never silently
-- dropped. Plus the consumers: purity labels and calls_commute.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local effects = require 'cartograph.effects'
local scc = require 'cartograph.scc'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
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
