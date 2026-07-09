-- Unit tests for parameter-origin tracing over a synthetic classified graph.

local store = require 'cartograph.store'
local trace = require 'cartograph.trace'

local function fn(id, name, opts)
    opts = opts or {}
    return { id = id, name = name, kind = 'function', file = opts.file or 'm.lua',
        range = { start = { line = opts.l or 0, char = 0 }, ['end'] = { line = (opts.l or 0) + 5, char = 0 } },
        order = 1, params = opts.params, rets = opts.rets, df = opts.df }
end

local function call(to, argv, opts)
    opts = opts or {}
    return { callee = to:match('::(.-)@') or to, to = to, argv = argv,
        args = {}, file = opts.file or 'm.lua', line = opts.line or 50,
        top = opts.fn == nil, fn = opts.fn }
end

local function graph(nodes, calls)
    store.ingest({ schema = 1, root = '/x', nodes = nodes, edges = {}, calls = calls })
end

local F = 'm.lua::f@10'
local G = 'm.lua::g@30'

test('trace: origins lists one entry per call site, classified', function ()
    graph({ fn(F, 'f', { params = { 'a', 'b' } }) },
        { call(F, { { k = 'lit', v = 1 }, { k = 'lit', v = 'x' } }, { line = 3 }),
          call(F, { { k = 'lit', v = 2 } },                        { line = 7 }) })
    local o = trace.origins(store, F, 2)
    eq(2, #o)
    eq('lit', o[1].v.k)      -- line 3: 'x'
    eq('x', o[1].v.v)
    eq('absent', o[2].v.k)   -- line 7: nothing passed for b
end)

test('trace: no resolved call sites -> empty with an honest note', function ()
    graph({ fn(F, 'f', { params = { 'a' } }) }, {})
    local o, note = trace.origins(store, F, 1)
    eq(0, #o)
    ok(note and note:match('dynamic'), 'says why')
end)

test('trace: a param origin expands up the call graph', function ()
    -- h(y) -> g passes its own param x on -> g is called with a literal
    graph({ fn(F, 'f', { params = { 'y' } }), fn(G, 'g', { params = { 'x' } }) },
        { call(F, { { k = 'param', name = 'x', i = 1 } }, { fn = G, line = 31 }),
          call(G, { { k = 'lit', v = 42 } },              { line = 1 }) })
    local o = trace.origins(store, F, 1)
    eq('param', o[1].v.k)
    local kids = trace.expand(store, o[1])
    eq(1, #kids)
    eq(42, kids[1].v.v)
end)

test('trace: a call origin expands through the target\'s returns', function ()
    graph({ fn(F, 'f', { params = { 'a' } }),
            fn(G, 'g', { rets = { { l = 32, vals = { { k = 'lit', v = 'ret' } } } } }) },
        { call(F, { { k = 'call', callee = 'g', to = G } }, { line = 5 }) })
    local o = trace.origins(store, F, 1)
    local kids = trace.expand(store, o[1])
    eq(1, #kids)
    eq('ret', kids[1].v.v)
    eq(G, kids[1].fn)
end)

test('trace: a local origin expands to its data-flow defs', function ()
    graph({ fn(F, 'f', { params = { 'a' } }),
            fn(G, 'g', { params = { 'p' }, df = { inputs = {},
                stmts = { { l = 31, def = { 's' }, use = { 'p' }, dep = {} } } } }) },
        { call(F, { { k = 'local', name = 's', l = 30 } }, { fn = G, line = 33 }) })
    local o = trace.origins(store, F, 1)
    local kids = trace.expand(store, o[1])
    eq(1, #kids)
    eq('def', kids[1].v.k)
    -- and the def expands into what it read: g's param p
    local kids2 = trace.expand(store, kids[1])
    eq('param', kids2[1].v.k)
    eq(1, kids2[1].v.i)
end)

test('trace: field and vararg are labelled frontiers; literals are terminal', function ()
    graph({ fn(F, 'f', { params = { 'a' } }) },
        { call(F, { { k = 'field', path = 't.speed' } }, { line = 1 }) })
    local o = trace.origins(store, F, 1)
    local kids, why = trace.expand(store, o[1])
    eq(nil, kids)
    ok(why and why:match('alias'), 'aliasing reason given')

    local lk, lwhy = trace.expand(store, { v = { k = 'lit', v = 5 } })
    eq(nil, lk)
    eq(nil, lwhy) -- terminal, not a frontier
end)

test('trace: unresolvable call target is a frontier with the callee named', function ()
    graph({ fn(F, 'f', { params = { 'a' } }) },
        { call(F, { { k = 'call', callee = 'require' } }, { line = 1 }) })
    local o = trace.origins(store, F, 1)
    local kids, why = trace.expand(store, o[1])
    eq(nil, kids)
    ok(why and why:match('require'), 'callee named in reason')
end)

test('trace: shadow disambiguation — a shadowed local traces its OWN defs', function ()
    -- needs a REAL file: binder resolution parses from disk (scope-model
    -- phase 1); synthetic-graph tests above exercise the name fallback
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.get_string_parser, '', 'lua') then
        skip 'no lua parser'
    end
    local ts = require 'cartograph.providers.treesitter'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat({
        'local function pick(flag)',    -- 1
        '    local mode = "outer"',     -- 2: outer def
        '    do',                       -- 3: compound stmt holding the shadow
        '        local mode = "inner"', -- 4: inner def (df reports row 3)
        '        use(mode)',            -- 5: INNER use
        '    end',                      -- 6
        '    return mode',              -- 7: OUTER use
        'end',
        'return { pick = pick }',
    }, '\n'))
    fd:close()
    store.ingest(ts.extract(root))
    local pick
    for id, n in pairs(store.by_id) do
        if n.name == 'pick' then pick = id end
    end
    ok(pick, 'pick found')
    -- INNER use (0-based line 4): before phase 1 this trace ALSO returned
    -- the outer def at line 2 — a false origin from another variable.
    -- Now: exactly the do-statement (the inner decl's containing stmt).
    local inner = trace.origins_local(store, pick, 'mode', 4)
    eq(1, #inner)
    eq(2, inner[1].site.line) -- 0-based row of the do-stmt
    -- OUTER use (0-based line 6): the simple outer def is kept; the
    -- compound stays too — df's statement granularity cannot separate a
    -- compound that CONTAINS a shadow-decl from one assigning the outer
    -- binder (the documented phase-1 residue; phase 2's binder tags own it)
    local outer = trace.origins_local(store, pick, 'mode', 6)
    eq(2, #outer)
    vim.fn.delete(root, 'rf')
end)
