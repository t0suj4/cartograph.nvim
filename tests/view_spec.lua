-- The view observable: symbols.on_view emits { labels, selected } whenever the
-- view changes, DEDUPED, and unsubscribe stops delivery. Driven by setting
-- line_node + calling emit_view directly — no rendered buffer needed (a
-- headless spec has no window, so `selected` is nil throughout).

local store = require 'cartograph.store'
local symbols = require 'cartograph.panes.symbols'

local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
local function mod(name) return { id = name, name = name, kind = 'module', file = name, range = R0, order = 0 } end

local function reset(nodes)
    store.ingest({ schema = 1, root = '/x', nodes = nodes, edges = {} })
    symbols._view_subs = {}
    symbols._last_viewkey = nil
    symbols.win = nil -- no window -> selected is nil
    symbols.line_node = {}
end

test('on_view: emits the visible labels (module basenames) in row order', function ()
    reset({ mod('lua/a.lua'), mod('lua/b.lua') })
    symbols.line_node = { [1] = 'lua/a.lua', [2] = 'lua/b.lua' }
    local got
    symbols.on_view(function (v) got = v end)
    symbols.emit_view()
    eq({ 'a.lua', 'b.lua' }, got.labels) -- basenames, sorted by row
    eq(nil, got.selected)                -- no window in a headless spec
end)

test('on_view: an unchanged view is deduped; a real change fires', function ()
    reset({ mod('a.lua'), mod('b.lua') })
    symbols.line_node = { [1] = 'a.lua' }
    local fires = 0
    symbols.on_view(function () fires = fires + 1 end)
    symbols.emit_view() -- nil -> {a} : fires
    symbols.emit_view() -- identical : deduped
    symbols.line_node = { [1] = 'a.lua', [2] = 'b.lua' }
    symbols.emit_view() -- {a} -> {a,b} : fires
    eq(2, fires)
end)

test('on_view: unsubscribe stops delivery', function ()
    reset({ mod('a.lua'), mod('b.lua') })
    symbols.line_node = { [1] = 'a.lua' }
    local fires = 0
    local unsub = symbols.on_view(function () fires = fires + 1 end)
    symbols.emit_view() -- fires (1)
    unsub()
    symbols.line_node = { [1] = 'a.lua', [2] = 'b.lua' }
    symbols.emit_view() -- no subscribers -> nothing
    eq(1, fires)
end)

test('on_view: no subscribers is a cheap no-op (no error)', function ()
    reset({ mod('a.lua') })
    symbols.line_node = { [1] = 'a.lua' }
    symbols.emit_view() -- must not error with an empty subscriber list
    ok(true)
end)
