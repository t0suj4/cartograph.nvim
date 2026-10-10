-- cartograph.flowtype — WHAT VALUE REACHES A RECEIVER, BY FLOW (CART-1621). An inclusion points-to analysis: the
-- functions / tables / types that flow to an AMBIGUOUS call's receiver decide it — one function (exact, possibly one
-- the name join never listed), a type (string), or nothing claimed when an unknown value may arrive.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local flowtype = require 'cartograph.flowtype'

local function tree(files)
    local root = vim.fn.tempname()
    for rel, src in pairs(files) do
        vim.fn.mkdir((root .. '/' .. rel):match('^(.*)/[^/]+$'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(src); fd:close()
    end
    return root
end

local FILES = {
    -- (two modules each defining `get` and `lower`: every `x.get()` / `s:lower()` below is AMBIGUOUS by name)
    ['a.lua'] = 'local A = {}\nfunction A.get(t) t.n = 1; return t end\nfunction A.lower(s) return s end\nreturn A\n',
    ['b.lua'] = 'local B = {}\nfunction B.get(t) t.m = 2; return t end\nfunction B.lower(s) return s end\nreturn B\n',
    ['main.lua'] = table.concat({
        -- a record of closures returned by a constructor: `r.get` is the closure, not A.get / B.get
        'local function reader(src)',
        '  return { get = function (i) return src:sub(i, i) end }',
        'end',
        'local function first(src)',
        '  local r = reader(src)',
        '  return r.get(1)',
        'end',
        -- a receiver only ever a string BY FLOW (the parameter of a local function its callers hand literals):
        -- name:lower() is string.lower, neither A.lower nor B.lower
        'local function shout(name)',
        '  return name:lower()',
        'end',
        'local function greet() return shout("ada"), shout("bob") end',
        -- a dispatch table called through pcall: the handler reached is the table's
        'local VERBS = { get = function (t) return t end }',
        'local function run(verb, t)',
        '  local h = VERBS[verb]',
        '  local ok, v = pcall(h, t)',
        '  return v',
        'end',
        'return { first = first, greet = greet, run = run }',
    }, '\n'),
}

test('flowtype: a returned record\'s closure, a string-only receiver — decided by what FLOWS there, not by the name', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree(FILES)
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false })
    vim.fn.delete(root, 'rf')
    local callrec = require 'cartograph.callrec'
    local by = {}
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'main.lua' then by[tostring(callrec.full(c) or callrec.callee(c))] = R.verdict(c) end
    end
    local g = by['r.get']
    eq('exact', g and g.kind, 'the record\'s closure: ' .. vim.inspect(g))
    ok(g and g.targets[1] and g.targets[1]:match('^main%.lua::'), 'a main.lua function — neither A.get nor B.get: ' .. vim.inspect(g))
    local s = by['name:lower']
    eq('string', s and s.kind, 'only a string reaches s: ' .. vim.inspect(s))
end)

test('flowtype: an EXPORTED function\'s parameter may hold anything (open) — no claim through it', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['a.lua'] = 'local A = {}\nfunction A.get(t) t.n = 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nfunction B.get(t) t.m = 2 end\nreturn B\n',
        ['m.lua'] = 'local M = {}\nlocal function g() return 1 end\nfunction M.use(x) return x.get() end\nfunction M.inside() return M.use({ get = g }) end\nreturn M\n',
    })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local call
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'x.get' then call = c end end
    ok(call, 'the ambiguous call is recorded')
    local closed = flowtype.of(store, { open = false }).verdict(call)
    eq('exact', closed and closed.kind, 'closed world: the one table that flows in decides it')
    eq(nil, flowtype.of(store).verdict(call), 'open (the default): M.use is exported — an outside caller may pass anything')
    vim.fn.delete(root, 'rf') -- (after: the analysis reads the sources)
end)

test('effects by flow: a joined call flow decides takes ITS target — not every same-named candidate\'s writes', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local effects = require 'cartograph.effects'
    local root = tree({
        ['a.lua'] = 'local A = {}\nlocal hits = 0\nfunction A.get() hits = hits + 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nlocal seen = 0\nfunction B.get() seen = seen + 1 end\nreturn B\n',
        ['main.lua'] = 'local function reader(src)\n  return { get = function (i) return i end }\nend\nlocal function first(src)\n  local r = reader(src)\n  return r.get(1)\nend\nreturn first\n',
    })
    store.ingest(ts.extract(root))
    local first
    for _, n in ipairs(store.data.nodes) do if n.name == 'first' then first = n end end
    store._fx = nil
    local by_name = effects.purity(store, first.id)
    store._fx = nil
    effects.FLOW = true
    local ok_, by_flow = pcall(effects.purity, store, first.id)
    effects.FLOW = nil
    store._fx = nil
    vim.fn.delete(root, 'rf')
    ok(ok_, tostring(by_flow))
    eq('writes~', by_name, 'the name join takes A.get and B.get: their writes')
    eq('pure~', by_flow, 'by flow, r.get is the record\'s closure: no write (a premise: ~)')
end)
