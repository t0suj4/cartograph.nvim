-- Param predicates + the effects discharge: "writes iff param i truthy",
-- resolved per call site against argv literals. gp is SKIP-direction
-- sound: a falsy flag proves no write; a truthy flag falls back to the
-- gw tier (other guards may gate); non-literals stay 'may-write'.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local effects = require 'cartograph.effects'

local function ready(lang)
    return pcall(vim.treesitter.language.add, lang)
end

test('effects: an ABSENT argument is nothing to mutate — unless the call\'s last argument can expand into it (CART-1670)', function ()
    if not ready('lua') then return end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat({
        'local M = {}',
        'local function put(t, k, m) if m then m[k] = true end; return t end', -- mutates its 3rd param
        'function M.get() return {} end',
        'function M.absent(x) return put(x, 1) end',          -- #3 not passed: nil, nothing reached
        'function M.expands(x) return put(x, M.get()) end',   -- #3 not written, but M.get() may return two values
        'function M.passes(x, m) return put(x, 1, m) end',    -- #3 is the caller's param: it writes ITS param
        'return M', '' }, '\n'))
    fd:close()
    store.ingest(ts.extract(root))
    local by = {}
    for _, n in ipairs(store.data.nodes) do if n.name then by[n.name] = n.id end end
    eq('pure', effects.purity(store, by['M.absent']), 'an absent 3rd argument: no caller table is mutated')
    ok(tostring(effects.purity(store, by['M.expands'])):find('~', 1, true), 'a trailing call may fill #3: still hedged')
    eq('writes', effects.purity(store, by['M.passes']), 'the caller\'s own param is mutated')
end)

test('effects: a bare call through a file\'s stable ALIAS of a builtin is that builtin — never when the alias is reassigned', function ()
    if not ready('lua') then return end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat({
        'local M = {}',
        'local byte, upper = string.byte, string.upper',
        'local sort = table.sort',
        'local find = string.find',
        'function M.b(s) return byte(s, 1), upper(s) end',    -- pure: string.byte / string.upper
        'function M.s(t) sort(t) end',                        -- writes its param: table.sort writes arg 1
        'function M.rebind() find = rawget(_G, "mystery") end',   -- reassigned to a value nothing resolves
        'function M.f(s) return find(s, "x") end',            -- find is reassigned: no alias claim
        'return M', '' }, '\n'))
    fd:close()
    store.ingest(ts.extract(root))
    local by = {}
    for _, n in ipairs(store.data.nodes) do if n.name then by[n.name] = n.id end end
    eq('pure', effects.purity(store, by['M.b']), 'byte / upper are string.byte / string.upper')
    eq('writes', effects.purity(store, by['M.s']), 'sort is table.sort: it writes its first argument (the param)')
    local pf = effects.purity(store, by['M.f'])
    ok(pf ~= 'pure', 'a reassigned alias is no string.find: whatever it holds now is unknown — ' .. tostring(pf))
end)

test('effects: a hedge names the call by its 1-based LINE, as an editor shows it (CART-1680)', function ()
    if not ready('lua') then return end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat({
        'local M = {}',                                -- 1
        'local function put(t, k) t[k] = true end',    -- 2
        'function M.f(k)',                             -- 3
        '  local x = get_from_somewhere()',            -- 4: an opaque local
        '  put(x, k)',                                 -- 5
        'end',
        'return M', '' }, '\n'))
    fd:close()
    store.ingest(ts.extract(root))
    local id
    for _, n in ipairs(store.data.nodes) do if n.name == 'M.f' then id = n.id end end
    local hs = table.concat((effects.summaries(store)[id] or {}).h or {}, ' | ')
    ok(hs:find('m.lua:5', 1, true), 'the hedge names line 5: ' .. hs)
end)

local function edge(data, fn_name, var_name)
    local byid = {}
    for _, n in ipairs(data.nodes) do byid[n.id] = n end
    for _, e in ipairs(data.edges) do
        if e.kind == 'use' then
            local f, v = byid[e.from], byid[e.to]
            if f and v and f.name == fn_name and v.name == var_name then
                return e
            end
        end
    end
end

local LUA_SRC = table.concat({
    'local state = {}',
    'local log = {}',
    'local mixed = {}',
    'local neg = {}',
    -- writes iff `flush` truthy (conjunct with another condition)
    'local function save(x, flush)',
    '    if flush and x then state.n = x end',
    'end',
    -- writes iff `quiet` FALSY
    'local function report(msg, quiet)',
    '    if not quiet then log.last = msg end',
    'end',
    -- conflicting predicates across writes: gp must die, gw stays guarded
    'local function both(a, b)',
    '    if a then mixed.x = 1 end',
    '    if b then mixed.x = 2 end',
    'end',
    -- else-arm bare param: writes iff param FALSY
    'local function fallback(v)',
    '    if v then use(v) else neg.d = 1 end',
    'end',
    'local function drive()',
    '    save(1, true)',
    '    save(2, false)',
    '    save(3)',
    '    save(4, cond)',
    '    report("a", true)',
    '    report("b")',
    'end',
    'return { save = save, report = report, both = both,',
    '    fallback = fallback, drive = drive }',
}, '\n')

test('paramfx: gp extraction — sign, conflict death, else-arm', function ()
    if not ready('lua') then skip 'no lua parser' end
    local data = ts.extract(mkroot('m.lua', LUA_SRC))
    eq(2, edge(data, 'save', 'state').gp, 'writes iff param 2 truthy')
    eq(-2, edge(data, 'report', 'log').gp, 'not-param: writes iff param 2 falsy')
    eq(nil, edge(data, 'both', 'mixed').gp, 'conflicting params: gp dead')
    eq(2, edge(data, 'both', 'mixed').gw, '...but still all-guarded')
    eq(-1, edge(data, 'fallback', 'neg').gp, 'else-arm bare param: negated')
end)

test('paramfx: call-site discharge against argv literals', function ()
    if not ready('lua') then skip 'no lua parser' end
    store.ingest(ts.extract(mkroot('m.lua', LUA_SRC)))
    local by = {} -- callee-name/arg1 -> verdict
    for _, c in ipairs(store.data.calls) do
        if c.to then
            for _, w in ipairs(effects.call_writes(store, c)) do
                local a1 = require('cartograph.argv').str(c, 1)
                if a1 == '' then
                    local a = require('cartograph.argv').at(c, 1)
                    a1 = a and a.v or '?'
                end
                by[(c.callee or '?') .. '/' .. a1] = w.verdict
            end
        end
    end
    eq('writes-guarded', by['save/1'], 'flush=true: predicate passes, gw tier')
    eq('skips', by['save/2'], 'flush=false: provably no write')
    eq('skips', by['save/3'], 'flush missing = nil in lua: provably no write')
    eq('may-write', by['save/4'], 'flush=<expr>: undischargeable')
    eq('skips', by['report/a'], 'quiet=true, negated predicate: no write')
    eq('writes-guarded', by['report/b'], 'quiet missing = falsy: fires, gw tier')
end)

test('paramfx: php gp + missing-arg stays may-write (defaults)', function ()
    if not ready('php') then skip 'no php parser' end
    local data = ts.extract(mkroot('m.php', table.concat({
        '<?php',
        '$store = array();',
        'function save($x, $flush) {',
        '    if ($flush && $x) { $store["n"] = $x; }',
        '}',
        'function drive() { save(1, true); save(2, false); save(3); }',
    }, '\n')))
    eq(2, edge(data, 'save', 'store').gp, 'php: writes iff param 2 truthy')
    store.ingest(data)
    local got = {}
    for _, c in ipairs(store.data.calls) do
        if c.to and c.callee == 'save' then
            local w = effects.call_writes(store, c)
            got[#got + 1] = w[1] and w[1].verdict or '?'
        end
    end
    table.sort(got)
    eq({ 'may-write', 'skips', 'writes-guarded' }, got,
        'true fires (gw tier), false skips, MISSING arg stays may-write (defaults)')
end)

test('purity inputs: pw — the param-mutation fact', function ()
    if not ready('lua') then skip 'no lua parser' end
    local data = ts.extract(mkroot('m.lua', table.concat({
        'local g = {}',
        'local function mut(t, opts)',       -- writes params 1 AND 2
        '    t.x = 1',
        '    opts.seen = true',
        '    local y = t.x',                 -- read: not a write fact
        'end',
        'local function pure(a, b) return a + b end',
        'local function modonly(v) g.last = v end', -- module write, no pw
        'local function shadow(x)',
        '    local t = {}',
        '    t.x = x',                       -- t is a LOCAL here, not a param
        'end',
        'return { mut, pure, modonly, shadow }',
    }, '\n')))
    local byname = {}
    for _, n in ipairs(data.nodes) do byname[n.name] = n end
    eq({ 1, 2 }, byname.mut.pw, 'both mutated params, sorted')
    eq(nil, byname.pure.pw, 'pure fn carries no pw')
    eq(nil, byname.modonly.pw, 'module-var write is not a param write')
    eq(nil, byname.shadow.pw, 'a local named like nothing: no false claim')
end)

test('purity inputs: flds — per-edge field facts, packed', function ()
    if not ready('lua') then skip 'no lua parser' end
    local data = ts.extract(mkroot('m.lua', table.concat({
        'local state = {}',
        'local function w()',
        '    state.x = 1',                       -- x: write, unguarded
        '    if not state.m then state.m = 1 end', -- m: set-once write (+read)
        '    return state.y, state.x',           -- y: read; x becomes rw
        'end',
        'local function whole() return pairs(state) end', -- '' bucket
        'return { w, whole }',
    }, '\n')))
    local e = (function ()
        local byid = {}
        for _, n in ipairs(data.nodes) do byid[n.id] = n end
        for _, ed in ipairs(data.edges) do
            if ed.kind == 'use' and byid[ed.from] and byid[ed.from].name == 'w'
                and byid[ed.to] and byid[ed.to].name == 'state' then
                return ed
            end
        end
    end)()
    ok(e and e.flds, 'field facts on the edge')
    -- packed: rw + gw*4
    eq(3, e.flds.x % 4, 'x read AND written')
    eq(1, (e.flds.x - e.flds.x % 4) / 4, 'x write unguarded: gw 1')
    eq(3, e.flds.m % 4, 'm: guard read + write')
    eq(3, (e.flds.m - e.flds.m % 4) / 4, 'm set-once: gw 3')
    eq(1, e.flds.y, 'y read-only, no guard tier')
    local e2 = (function ()
        local byid = {}
        for _, n in ipairs(data.nodes) do byid[n.id] = n end
        for _, ed in ipairs(data.edges) do
            if ed.kind == 'use' and byid[ed.from] and byid[ed.from].name == 'whole' then
                return ed
            end
        end
    end)()
    ok(e2 and e2.flds and e2.flds[''] == 1, 'whole-var read lands in the empty bucket')
end)

test('purity inputs: php param writes are VALUE-semantics — no pw', function ()
    if not ready('php') then skip 'no php parser' end
    local data = ts.extract(mkroot('m.php', table.concat({
        '<?php',
        'function mut($a) { $a["k"] = 1; return $a; }', -- mutates a COPY
    }, '\n')))
    for _, n in ipairs(data.nodes) do
        if n.name == 'mut' then
            eq(nil, n.pw, 'php array param write mutates a local copy: no fact')
        end
    end
end)
