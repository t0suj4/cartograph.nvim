-- A DEEP SYNTAX TREE MUST NOT KILL THE EXTRACTION (CART-1082).
--
-- Two walkers recursed once per tree level — flow.lua's du `rec` and
-- collect_mentions' `walk` — and one Lua stack holds only ~2000-3000 of their
-- frames. wine's dlls/d3d11/tests/d3d11.c has a 3177-deep `comma_expression`
-- chain (tree-sitter-c misparses an `#if 0` block inside an array initializer),
-- and the `stack overflow` it raised took down the WHOLE extraction: no graph for
-- wine at all.
--
-- The fixture is the witness's shape: `x = y, 0, 1, …, N-1;` inside a function.
-- A comma expression is LEFT-associative, so `x = y` sits at the DEEPEST level —
-- the def, the use and the mention the assertions read are exactly the ones past
-- the old overflow depth, so a walker that silently stopped early fails here too.
--
-- ⚠ BOTH HALVES ARE PINNED: the deep file is compared against the SAME function at
-- a shallow depth, so "extracts without raising" cannot pass by dropping rows.

local ts = require 'cartograph.providers.treesitter'
local flow = require 'cartograph.flow'

local DEEP = 5000 -- measured: 2000 levels passed the recursive walkers, 3000 overflowed

local function fixture(n)
    local items = {}
    for i = 0, n - 1 do items[#items + 1] = tostring(i) end
    return mkroot('deep.c', table.concat({
        'int x;',
        'void f(void)',
        '{',
        '    int y = 7;',
        '    x = y, ' .. table.concat(items, ', ') .. ';',
        '}',
        'int g(void) { return x; }',
    }, '\n') .. '\n')
end

--- extract one fixture; returns the fn nodes by name, f's flow rows as def/use
--- pairs, and the use edges keyed "from>to" (the kind and rw bits).
local function facts(n)
    local root = fixture(n)
    local okx, g = pcall(ts.extract, root, {})
    vim.fn.delete(root, 'rf')
    if not okx then error('extract raised at depth ' .. n .. ': ' .. tostring(g), 0) end
    local fns, byid = {}, {}
    for _, nd in ipairs(g.nodes) do
        byid[nd.id] = nd
        if nd.kind == 'function' then fns[nd.name] = nd end
    end
    local rows = {}
    for _, r in ipairs(flow.rows(fns.f)) do
        rows[#rows + 1] = { l = r.l, def = r.def, use = r.use }
    end
    local uses = {}
    for _, e in ipairs(g.edges) do
        if e.kind == 'use' then
            uses[byid[e.from].name .. '>' .. byid[e.to].name] = e.rw
        end
    end
    return { fns = fns, rows = rows, uses = uses, unparsed = g.unparsed }
end

test('deeptree: parser_available(c) — the fixture language', function()
    ok(parser_available('c'), 'the c grammar ships with nvim; if this skips, every test below is vacuous')
end)

test('deeptree: a 5000-deep comma chain extracts, and both functions are in the graph', function()
    if not parser_available('c') then skip('no c parser') end
    local d = facts(DEEP)
    ok(d.fns.f, 'the deep function f has a node')
    ok(d.fns.g, 'the function AFTER the deep one (g) has a node — the file was not abandoned')
    eq(nil, d.unparsed, 'the file is not reported unparsed')
end)

test('deeptree: du reads the def and use at the bottom of the chain (flow rows)', function()
    if not parser_available('c') then skip('no c parser') end
    local shallow, deep = facts(20), facts(DEEP)
    -- the positive half, stated outright, so equality of two empty lists cannot pass
    eq({ { l = 4, def = { 'y' }, use = {} }, { l = 5, def = { 'x' }, use = { 'y' } } },
        shallow.rows, 'shallow f: the reference rows')
    eq(shallow.rows, deep.rows, 'deep f: the same rows as the shallow twin')
end)

test('deeptree: the mention walk reaches the bottom of the chain (use edges)', function()
    if not parser_available('c') then skip('no c parser') end
    local shallow, deep = facts(20), facts(DEEP)
    ok(shallow.uses['f>x'], 'shallow f: a use edge to x exists')
    ok(shallow.uses['g>x'], 'shallow g: a use edge to x exists')
    eq(shallow.uses, deep.uses, 'deep: the same use edges and rw bits as the shallow twin')
end)
