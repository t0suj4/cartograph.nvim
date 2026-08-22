-- FILLING THE WORKING SET FROM WHAT IS ON SCREEN (CART-0520), and the
-- composition that makes it pay: a filled set is a CUT.
--
-- The set's only way in was one row at a time, which made it a chore rather than
-- the natural OUTPUT of navigation -- while every axis already produces a set.

local store = require 'cartograph.store'
local symbols = require 'cartograph.panes.symbols'
local cut = require 'cartograph.cut'
local ts = require 'cartograph.providers.treesitter'

local function has_parser(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang)
end

local function build()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'm.lua', {
        'local function leaf_a() return 1 end',
        'local function leaf_b() return 2 end',
        'local function hub()',
        '    return leaf_a() + leaf_b()',
        'end',
        'return { hub = hub }',
    })
    store.ingest(ts.extract(root))
    -- a fresh working set per test: the real one persists per project root
    store.workset = { ids = {}, refs = {}, pending = {}, last = nil }
    symbols.create(); symbols.win = nil
    return root
end

test('wsfill: marking a view takes every symbol row at once', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local root = build()
    -- stand on the CALLEES axis of hub: the rows ARE the set, and the traversal
    -- that drew them is already paid
    store.set_focus('m.lua::hub@2')
    symbols.show('axis', 'callees\31m.lua::hub@2')
    symbols.render()
    local rows = 0
    for _ in pairs(symbols.line_node or {}) do rows = rows + 1 end
    ok(rows >= 2, 'the axis lists the callees (' .. rows .. ')')
    symbols.ws_toggle_view()
    eq(rows, #store.ws_list(), 'every row is now in the set')
    ok(store.ws_has('m.lua::leaf_a@0'), 'including leaf_a')
    vim.fn.delete(root, 'rf')
end)

test('wsfill: marking a fully-marked view UNMARKS it (subtract)', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local root = build()
    store.set_focus('m.lua::hub@2')
    symbols.show('axis', 'callees\31m.lua::hub@2')
    symbols.render()
    symbols.ws_toggle_view()
    local n = #store.ws_list()
    ok(n > 0)
    symbols.ws_toggle_view()
    eq(0, #store.ws_list(), 'the same gesture takes them back out')
    vim.fn.delete(root, 'rf')
end)

test('wsfill: a PARTIALLY marked view fills the rest (union, not toggle)', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local root = build()
    store.ws_toggle('m.lua::leaf_a@0')          -- one member already in
    store.set_focus('m.lua::hub@2')
    symbols.show('axis', 'callees\31m.lua::hub@2')
    symbols.render()
    local rows = 0
    for _ in pairs(symbols.line_node or {}) do rows = rows + 1 end
    symbols.ws_toggle_view()
    eq(rows, #store.ws_list(),
        'a half-marked view is COMPLETED rather than inverted — otherwise adding a'
        .. ' second axis to a set would remove the first')
    vim.fn.delete(root, 'rf')
end)

test('wsfill: the working set IS a cut, and cut.of_nodes finally has a caller', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local root = build()
    store.ws_toggle('m.lua::leaf_a@0')
    store.ws_toggle('m.lua::leaf_b@1')
    local sc = cut.of_frame(store, 'ws', 'ws')
    ok(sc, 'standing at the working set yields a cut, not nil')
    eq('set', sc.grain, 'an arbitrary union of nodes: grain `set`')
    eq(2, #sc.spans, 'one span per member')
    ok(sc.label:match('working set'), sc.label)
    -- and a promise rule still refuses over it: a union of nodes holds nobody's
    -- whole search space, so `set` is deliberately absent from lint.CLOSURE
    local lint = require 'cartograph.lint'
    eq(false, lint.policies({ quantifier = 'promise', closed_over = 'fn' }, 'set').clip)
    vim.fn.delete(root, 'rf')
end)

test('wsfill: a view with no symbol rows says so instead of marking nothing', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local root = build()
    symbols.show('ws')       -- an EMPTY working set has no node rows
    symbols.render()
    symbols.ws_toggle_view()
    eq(0, #store.ws_list())
    vim.fn.delete(root, 'rf')
end)
