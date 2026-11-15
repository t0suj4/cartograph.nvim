-- CART-2101 (the user's design, kb current-item-selection-design): the list pane publishes its CURRENT ITEM — an item
-- (node id + typed GRAPH position) or a non-item row's kind — plus the raw cursor; consumers OPT IN to what they follow;
-- a row the source marks local-only reaches a protocol client as "not shared"; a replay records the item, not a row.
-- (The forwarded-key half — every movement reaching the one publish path — is listcursor_spec's, in a real main loop.)

local ts      = require 'cartograph.providers.treesitter'
local store   = require 'cartograph.store'
local symbols = require 'cartograph.panes.symbols'
local source  = require 'cartograph.panes.source'
local agent   = require 'cartograph.agent'

local function setup()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write('local M = {}\nfunction M.alpha(x)\n  return x\nend\nfunction M.beta(y)\n  return y\nend\nreturn M\n')
    fd:close()
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    local ids = {}
    for _, n in ipairs(store.data.nodes) do ids[n.name] = n.id end
    vim.cmd('tabnew')
    local wsrc = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsrc, source.create()); source.attach(wsrc)
    vim.cmd('leftabove vsplit')
    local wsym = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsym, symbols.create()); symbols.attach(wsym)
    symbols.CURSOR_SETTLE_MS = 0
    symbols.show('file', 'm.lua')
    local rows = {}
    for r = 1, vim.api.nvim_buf_line_count(symbols.buf) do
        local id = symbols.line_node[r]
        if id == ids['M.alpha'] then rows.alpha = r elseif id == ids['M.beta'] then rows.beta = r
        elseif not id and not rows.other then rows.other = r end
    end
    local function go(r) -- a settled move, as nvim delivers a typed one
        vim.api.nvim_win_set_cursor(wsym, { r, 0 })
        vim.api.nvim_exec_autocmds('CursorMoved', { buffer = symbols.buf })
        -- (a CONDITION wait with a generous ceiling: under the parallel suite the settle timer can slip past 100 ms,
        -- and the publish then landed after the assertion read nil)
        vim.wait(2000, function () return symbols.selection and symbols.selection.row == r end, 5)
    end
    local function done()
        symbols.CURSOR_SETTLE_MS = 60; symbols.share_selection = false
        vim.cmd('tabclose'); vim.fn.delete(root, 'rf')
    end
    return { ids = ids, rows = rows, go = go, done = done, wsym = wsym }
end

test('selection: an item row publishes { item, node, typed pos }; a non-item row its KIND; both carry the raw cursor (CART-2101)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local t = setup()
    ok(t.rows.alpha and t.rows.beta and t.rows.other, 'the fixture has item rows and a non-item row: ' .. vim.inspect(t.rows))
    t.go(t.rows.alpha)
    local s = symbols.selection
    eq('item', s.kind); eq(t.ids['M.alpha'], s.node)
    eq({ line = 1, col = 0, lb = 0, cb = 0, unit = 'byte' }, s.pos, 'the node\'s own start, a GRAPH position')
    eq(t.rows.alpha, s.cursor.row); eq('file', s.level)
    t.go(t.rows.other)
    ok(symbols.selection.kind ~= 'item', 'a non-item row is published as its kind: ' .. tostring(symbols.selection.kind))
    eq(nil, symbols.selection.node)
    eq({ kind = 'item', node = t.ids['M.alpha'] }, symbols.selection_key(symbols.selection_at(t.rows.alpha)), 'a replay key is the item')
    t.done()
end)

test('selection: consumers OPT IN — item followers skip non-item rows, selection followers see every one, cursor followers get the raw cursor; meta only on request (CART-2101)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local t = setup()
    local seen = { item = {}, sel = {}, cur = {}, meta = {} }
    local u1 = symbols.subscribe { follow = 'item', fn = function (s) seen.item[#seen.item + 1] = s.node end }
    local u2 = symbols.subscribe { follow = 'selection', fn = function (s) seen.sel[#seen.sel + 1] = s.kind; seen.nometa = s.meta end }
    local u3 = symbols.subscribe { follow = 'cursor', fn = function (s) seen.cur[#seen.cur + 1] = s.cursor.row; seen.curnode = s.node end }
    local u4 = symbols.subscribe { follow = 'selection', meta = true, fn = function (s) seen.meta[#seen.meta + 1] = s.meta end }
    t.go(t.rows.alpha); t.go(t.rows.other); t.go(t.rows.alpha); t.go(t.rows.beta)
    eq({ t.ids['M.alpha'], t.ids['M.beta'] }, seen.item, 'item: only when the ITEM changes — a non-item row in between is not an item change')
    eq(4, #seen.sel, 'selection: every publish')
    eq({ t.rows.alpha, t.rows.other, t.rows.alpha, t.rows.beta }, seen.cur, 'cursor: the raw rows')
    eq(nil, seen.curnode, 'a cursor follower is not handed the item')
    eq(nil, seen.nometa, 'no metadata unless asked')
    ok(seen.meta[1] and seen.meta[1].file == 'm.lua', 'metadata when asked: ' .. vim.inspect(seen.meta[1]))
    ok(not pcall(symbols.subscribe, { follow = 'everything', fn = print }), 'an unknown follow is refused, never defaulted')
    u1(); u2(); u3(); u4()
    t.done()
end)

test('selection: a protocol client gets "not shared" until the source opts in, and never a local-only row (CART-2101)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local t = setup()
    t.go(t.rows.alpha)
    local a = agent.answer(store, 'selection', {})
    eq({ { shared = false, why = 'not shared' } }, a.result, 'sharing is opt-in: nothing of the item crosses')
    symbols.share_selection = true
    a = agent.answer(store, 'selection', {})
    eq(true, a.result[1].shared); eq('item', a.result[1].kind); eq(t.ids['M.alpha'], a.result[1].node)
    eq(2, a.result[1].line, 'protocol positions are 1-based (the agent\'s profile)')
    eq(1, a.result[1].col, 'and a 1-based CHARACTER column')
    symbols.line_local[t.rows.beta] = true -- the source marks a row local-only
    t.go(t.rows.beta)
    a = agent.answer(store, 'selection', {})
    eq({ { shared = false, why = 'not shared' } }, a.result, 'a local-only row is "not shared" even when sharing is on — never its content')
    t.done()
end)

test('selection: the live altitude\'s rows are local-only — runtime values never reach a protocol client (CART-2101)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local t = setup()
    symbols.show('live', 'm.lua\31nothing-here')
    ok(vim.api.nvim_buf_line_count(symbols.buf) >= 1, 'the live view rendered')
    for r = 1, vim.api.nvim_buf_line_count(symbols.buf) do eq(true, symbols.line_local[r], 'row ' .. r .. ' is local-only') end
    t.done()
end)

test('selection: a trail entry records the selected ITEM, and h comes back to it (CART-2101)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local t = setup()
    t.go(t.rows.beta)
    vim.api.nvim_set_current_win(t.wsym)
    vim.cmd('normal ' .. require('cartograph.config').keys.descend)
    local e = symbols.trail[#symbols.trail]
    ok(e and e.sel, 'the trail entry carries a selection key: ' .. vim.inspect(e))
    eq({ kind = 'item', node = t.ids['M.beta'] }, e.sel)
    -- the list SHIFTED since (simulated: the recorded row now holds another item): h lands on the ITEM, not the row
    e.row = t.rows.alpha
    vim.cmd('normal ' .. require('cartograph.config').keys.ascend)
    eq(t.rows.beta, vim.api.nvim_win_get_cursor(t.wsym)[1], 'restored onto M.beta, wherever its row is')
    t.done()
end)
