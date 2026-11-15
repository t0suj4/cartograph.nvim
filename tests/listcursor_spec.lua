-- CART-2097: the symbols pane's cursor dependents (hover preview, source follow, highlight, emit_view) follow the
-- PUBLISHED list cursor, not CursorMoved — so a key forwarded into the pane from another window (nvim_win_call +
-- `normal`, the 2D plane's mechanism, W3 gate S0) updates them. nvim fires CursorMoved only for the window current when
-- its main loop checks, so a forwarded j moved the cursor and left every dependent stale (14 of 23 gate steps).
--
-- No autocmd is fired by hand on the FORWARDED path: the mapping runs inside nvim_win_call exactly as the plane runs it.
-- The TYPED path fires CursorMoved by hand once, right after the key, because that is what nvim's main loop does for a
-- typed key and the spec runner has no main loop — it pins that a delivered move adds nothing of the pane's own.

local ts      = require 'cartograph.providers.treesitter'
local store   = require 'cartograph.store'
local symbols = require 'cartograph.panes.symbols'
local source  = require 'cartograph.panes.source'
local config  = require 'cartograph.config'

local function setup()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat({
        'local M = {}',
        'function M.alpha(x)',
        '    return x + 1',
        'end',
        'function M.beta(y)',
        '    return y * 2',
        'end',
        'return M', '' }, '\n'))
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
    vim.wait(100, function () return false end, 5) -- the landing settles
    local ra
    for r = 1, vim.api.nvim_buf_line_count(symbols.buf) do
        if symbols.line_node[r] == ids['M.alpha'] then ra = r end
    end
    ok(ra and symbols.line_node[ra + 1] == ids['M.beta'], 'alpha and beta are adjacent rows: '
        .. vim.inspect(vim.api.nvim_buf_get_lines(symbols.buf, 0, -1, false)))
    vim.api.nvim_win_set_cursor(wsym, { ra, 2 }) -- (no CursorMoved: the start is not a move)
    local seen = { cm = 0, emits = 0, pubs = {} }
    local au = vim.api.nvim_create_autocmd('CursorMoved', { buffer = symbols.buf,
        callback = function () seen.cm = seen.cm + 1 end })
    local unview = symbols.on_view(function () seen.emits = seen.emits + 1 end)
    local uncur = symbols.on_cursor(function (c) seen.pubs[#seen.pubs + 1] = c end)
    store.set_context(nil)
    local function done()
        vim.api.nvim_del_autocmd(au); unview(); uncur()
        symbols.CURSOR_SETTLE_MS = 60
        vim.cmd('tabclose'); vim.fn.delete(root, 'rf')
    end
    return { ids = ids, wsrc = wsrc, wsym = wsym, ra = ra, seen = seen, done = done }
end

test('list cursor: a j FORWARDED by nvim_win_call from another window updates the hover, the published cursor, emit_view and the pane\'s CursorMoved (CART-2097)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local t = setup()
    vim.api.nvim_set_current_win(t.wsrc) -- the forwarder's window is current, as in the plane
    vim.api.nvim_win_call(t.wsym, function () vim.cmd('normal ' .. config.keys.down) end)
    eq(t.ra + 1, vim.api.nvim_win_get_cursor(t.wsym)[1], 'the forwarded key moved the pane cursor')
    vim.wait(500, function () return #t.seen.pubs > 0 end, 5)
    eq(1, #t.seen.pubs, 'one settled publication')
    eq(t.ids['M.beta'], t.seen.pubs[1].node, 'the published cursor names the row it settled on')
    eq(t.ids['M.beta'], symbols.cursor and symbols.cursor.node)
    eq(t.ids['M.beta'], store.context and store.context.node, 'the hover preview followed')
    eq(1, t.seen.emits, 'emit_view ran for the new selection')
    eq(1, t.seen.cm, 'the pane emitted its CursorMoved for the undelivered move, once')
    eq(t.wsrc, vim.api.nvim_get_current_win(), 'focus never left the forwarder')
    -- a forwarded count, and the move back
    vim.api.nvim_win_call(t.wsym, function () vim.cmd('normal ' .. config.keys.up) end)
    vim.wait(500, function () return #t.seen.pubs > 1 end, 5)
    eq(t.ids['M.alpha'], store.context and store.context.node, 'k forwarded: the preview followed back')
    t.done()
end)

test('list cursor: a TYPED j that nvim delivers is published once from its CursorMoved — the pane adds no event of its own (CART-2097)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local t = setup()
    vim.api.nvim_set_current_win(t.wsym)
    vim.cmd('normal ' .. config.keys.down)                        -- the mapping, as a typed key runs it
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = symbols.buf }) -- what nvim's main loop fires next
    vim.wait(500, function () return #t.seen.pubs > 0 end, 5)
    vim.wait(50, function () return false end, 5)                  -- (room for a stray second event)
    eq(1, t.seen.cm, 'only nvim\'s CursorMoved: nothing emitted by the pane')
    eq(1, #t.seen.pubs, 'one publication')
    eq(t.ids['M.beta'], store.context and store.context.node, 'the hover preview followed, as before')
    -- a j that does not move (the last row) publishes nothing
    local last = vim.api.nvim_buf_line_count(symbols.buf)
    vim.api.nvim_win_set_cursor(t.wsym, { last, 0 })
    local n = #t.seen.pubs
    vim.api.nvim_set_current_win(t.wsrc)
    vim.api.nvim_win_call(t.wsym, function () vim.cmd('normal ' .. config.keys.down) end)
    vim.wait(100, function () return false end, 5)
    eq(n, #t.seen.pubs, 'no move, no publication')
    t.done()
end)
