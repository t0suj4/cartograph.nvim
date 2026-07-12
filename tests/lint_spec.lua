-- Unit tests for the graph-aware lint rules.

local store = require 'cartograph.store'
local lint  = require 'cartograph.lint'

local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
local function mod(file, effects) return { id = file, name = file, kind = 'module', file = file, range = R0, order = 0, effects = effects } end
local function fn(file, name, kind) return { id = file .. '::' .. name, name = name, kind = kind or 'function', file = file, range = R0, order = 0 } end
local function ref(a, b) return { from = a, to = b, kind = 'ref', at = {} } end
local function import(from, to, se) return { from = from, to = to, kind = 'import', sideeffect = se } end
local function graph(nodes, edges) store.ingest({ schema = 1, root = '/x', nodes = nodes, edges = edges or {} }) end

local function only(name) return { only = { [name] = true } } end
local function messages(findings) local m = {} for _, f in ipairs(findings) do m[#m + 1] = f.message end return m end

test('lint: a local function with no callers is flagged dead', function ()
    -- M.run is an exported entry point (no static caller, but public); it calls
    -- `used`; `orphan` is a local nobody calls.
    graph({ mod('m.lua'), fn('m.lua', 'orphan'), fn('m.lua', 'M.run'), fn('m.lua', 'used') },
          { ref('m.lua::M.run', 'm.lua::used') })
    local f = lint.run(store, only('dead-function'))
    local names = table.concat(messages(f), '\n')
    ok(names:match("'orphan'"), 'orphan flagged')
    ok(not names:match("'used'"), 'used (has a caller) not flagged')
    ok(not names:match("M%.run"), 'exported entry point not flagged')
end)

test('lint: an exported no-caller function is NOT flagged (public surface)', function ()
    graph({ mod('m.lua'), fn('m.lua', 'M.api'), fn('m.lua', 'mt:method', 'method') }, {})
    local f = lint.run(store, only('dead-function'))
    eq(0, #f)
end)

test('lint: a metamethod is NOT flagged (dispatched via metatable, never by name)', function ()
    graph({ mod('m.lua'), fn('m.lua', '__index'), fn('m.lua', 'mt:__newindex', 'method') }, {})
    eq(0, #lint.run(store, only('dead-function')))
end)

test('lint: a redundant require (pure module, discarded) is flagged', function ()
    graph({ mod('pure.lua', false), fn('pure.lua', 'f') },
          { import('caller.lua', 'pure.lua', true) })  -- discarded require of a pure module
    local f = lint.run(store, only('redundant-require'))
    eq(1, #f)
    ok(f[1].message:match('redundant'), f[1].message)
end)

test('lint: a side-effecting module required for effect is NOT redundant', function ()
    graph({ mod('patch.lua', true), fn('patch.lua', 'f') },
          { import('caller.lua', 'patch.lua', true) })
    eq(0, #lint.run(store, only('redundant-require')))
end)

test('lint: mutual recursion is a call cycle; plain recursion is not', function ()
    graph({ mod('m.lua'), fn('m.lua', 'a'), fn('m.lua', 'b'), fn('m.lua', 'r') },
          { ref('m.lua::a', 'm.lua::b'), ref('m.lua::b', 'm.lua::a'),
            ref('m.lua::r', 'm.lua::r') })  -- r calls itself
    local f = lint.run(store, only('call-cycle'))
    eq(1, #f)                                   -- only the a<->b cycle
    ok(f[1].message:match('a <%-> b'), f[1].message)
end)

test('lint: silent-drop flags a bare call to a local callable, neither resolved nor refused', function ()
    -- run(handler): `handler` is a param (a local callable). Three call sites:
    --  1. handler()     — unresolved + NOT refused → the silent honesty gap
    --  2. external_fn() — a FREE name (not a local) resolving to nil → honest external, NOT flagged
    --  3. handler()     — but honestly REFUSED → not silent, NOT flagged
    local caller = fn('m.lua', 'run'); caller.params = { 'handler' }
    store.ingest({ schema = 1, root = '/x', nodes = { mod('m.lua'), caller }, edges = {},
        calls = {
            { callee = 'handler', fn = 'm.lua::run', file = 'm.lua', at = R0 },
            { callee = 'external_fn', fn = 'm.lua::run', file = 'm.lua', at = R0 },
            { callee = 'handler', fn = 'm.lua::run', file = 'm.lua', at = R0, refused = { rule = 'ambiguous' } },
        } })
    local f = lint.run(store, only('silent-drop'))
    eq(1, #f) -- only the silent handler() (deduped per (fn,local); external + refused excluded)
    ok(f[1].message:match("'handler'"), f[1].message)
    ok(f[1].message:match('silent honesty gap'), f[1].message)
end)

test('lint: silent-drop ignores resolved, dynamic, qualified, and short-name calls', function ()
    local caller = fn('m.lua', 'run'); caller.params = { 'handler', 'obj', 'go' }
    store.ingest({ schema = 1, root = '/x', nodes = { mod('m.lua'), caller }, edges = {},
        calls = {
            { callee = 'handler', fn = 'm.lua::run', file = 'm.lua', at = R0, to = 'm.lua::run' }, -- resolved
            { callee = 'handler', fn = 'm.lua::run', file = 'm.lua', at = R0, dynamic = true },    -- dynamic frontier
            { callee = 'method', full = 'obj.method', fn = 'm.lua::run', file = 'm.lua', at = R0 }, -- qualified (receiver-typing, not this rule)
            { callee = 'go', fn = 'm.lua::run', file = 'm.lua', at = R0 }, -- short name (<3): resolution noise, not a gap
        } })
    eq(0, #lint.run(store, only('silent-drop')))
end)
