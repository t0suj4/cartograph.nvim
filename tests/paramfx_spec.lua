-- Param predicates + the effects discharge: "writes iff param i truthy",
-- resolved per call site against argv literals. gp is SKIP-direction
-- sound: a falsy flag proves no write; a truthy flag falls back to the
-- gw tier (other guards may gate); non-literals stay 'may-write'.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local effects = require 'cartograph.effects'

local function ready(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang)
end

local function mkroot(name, src)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/' .. name, 'w'))
    fd:write(src)
    fd:close()
    return root
end

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
