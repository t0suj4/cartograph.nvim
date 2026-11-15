-- CART-2097 / CART-2098: the symbols pane's cursor dependents (hover preview, source follow, highlight, emit_view)
-- follow the PUBLISHED list cursor, and a move nvim does not deliver — a key forwarded into the pane from another window
-- by nvim_win_call (the 2D plane's mechanism, W3 gate S0) — is caught at SafeState and delivered on ONE path. nvim fires
-- CursorMoved only for the window current when its main loop checks, so before this a forwarded j / G / gg / search moved
-- the cursor and left every dependent stale.
--
-- ★ THE INSTRUMENT IS A REAL MAIN LOOP. SafeState is nvim's main loop going idle and the spec runner has none, so this
-- drives an `--embed` child over RPC exactly as the plane is driven: keys arrive by nvim_input, a forwarded key is a
-- mirror window's mapping that runs nvim_win_call into the pane. Nothing fires an autocmd by hand. Each forwarded key is
-- compared with the SAME key TYPED into the pane, from the same start — typed input is the reference.

local repo = vim.fn.getcwd()

local CHILD = [==[
local root = ...
local ts, store = require 'cartograph.providers.treesitter', require 'cartograph.store'
local symbols, source = require 'cartograph.panes.symbols', require 'cartograph.panes.source'
local data = ts.extract(root); data.root = root
store.ingest(data)
local wsrc = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(wsrc, source.create()); source.attach(wsrc)
vim.cmd('leftabove vsplit')
local wsym = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(wsym, symbols.create()); symbols.attach(wsym)
symbols.CURSOR_SETTLE_MS = 0
symbols.show('file', 'm.lua')
vim.cmd('belowright split')
local wmir = vim.api.nvim_get_current_win()
local mbuf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(wmir, mbuf)
_G.T = { cm = 0, pubs = 0, wsym = wsym, wmir = wmir }
vim.api.nvim_create_autocmd('CursorMoved', { buffer = symbols.buf, callback = function () T.cm = T.cm + 1 end })
symbols.on_cursor(function () T.pubs = T.pubs + 1 end)
-- the mirror's forwarding mappings: <F5>..<F9> run G / gg / a search / j / k IN the pane, focus staying here
local FWD = { ['<F5>'] = 'G', ['<F6>'] = 'gg', ['<F7>'] = '/M.gamma\r', ['<F8>'] = 'j', ['<F9>'] = 'k' }
for lhs, keys in pairs(FWD) do
    vim.keymap.set('n', lhs, function ()
        vim.api.nvim_win_call(wsym, function () vim.cmd('normal ' .. keys) end)
    end, { buffer = mbuf })
end
function T.start(where, at) -- the same start for every key (row 1, or the LAST row for at = -1), then the focus
    vim.api.nvim_win_set_cursor(wsym, { at == -1 and vim.api.nvim_buf_line_count(symbols.buf) or 1, 0 })
    vim.api.nvim_set_current_win(wsym) -- (current, so nvim itself delivers the start)
    T.where = where
end
function T.focus() vim.api.nvim_set_current_win(T.where == 'typed' and wsym or wmir); T.cm, T.pubs = 0, 0 end
function T.snap()
    local r = vim.api.nvim_win_get_cursor(wsym)[1]
    return { row = r, node = symbols.line_node[r] or vim.NIL,
        published = symbols.cursor and symbols.cursor.row or vim.NIL,
        context = store.context and store.context.node or vim.NIL,
        highlight = vim.inspect(store.highlight), cm = T.cm, pubs = T.pubs,
        mirror_current = vim.api.nvim_get_current_win() == wmir }
end
return true
]==]

local function child(root)
    local xdg = vim.fn.tempname(); vim.fn.mkdir(xdg, 'p')
    local env = { XDG_STATE_HOME = xdg, XDG_CACHE_HOME = xdg, XDG_DATA_HOME = xdg, XDG_CONFIG_HOME = xdg }
    local ch = vim.fn.jobstart({ 'nvim', '--embed', '--headless', '-u', 'NONE', '--noplugin',
        '--cmd', 'set rtp^=' .. repo }, { rpc = true, env = env })
    assert(ch > 0, 'jobstart failed')
    vim.rpcrequest(ch, 'nvim_exec_lua', CHILD, { root })
    return ch, xdg
end

local function fixture()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    local src = { 'local M = {}' }
    for _, n in ipairs({ 'alpha', 'beta', 'gamma', 'delta', 'epsilon' }) do
        vim.list_extend(src, { 'function M.' .. n .. '(x)', '    return x', 'end' })
    end
    src[#src + 1] = 'return M'
    fd:write(table.concat(src, '\n') .. '\n'); fd:close()
    return root
end

-- one key, from the common start, through `where` ('typed' into the pane, or 'forwarded' from the mirror)
local function run(ch, where, keys, at)
    local function lua(code) return vim.rpcrequest(ch, 'nvim_exec_lua', code, {}) end
    vim.rpcrequest(ch, 'nvim_exec_lua', 'T.start(...)', { where, at or 1 })
    vim.wait(150, function () return false end, 10) -- the start settles
    lua('T.focus()')
    vim.wait(50, function () return false end, 10)
    vim.rpcrequest(ch, 'nvim_input', keys)
    vim.wait(250, function () return false end, 10)
    return lua('return T.snap()')
end

test('list cursor: G, gg, a search, j and k FORWARDED by nvim_win_call update the published cursor and its dependents exactly as typed (CART-2098, CART-2097)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = fixture()
    local ch, xdg = child(root)
    local CASES = { { 'G', '<F5>' }, { 'gg', '<F6>', -1 }, { '/M.gamma<CR>', '<F7>' }, { 'j', '<F8>' } }
    local hovered = 0
    for _, c in ipairs(CASES) do
        local typed, fwd = run(ch, 'typed', c[1], c[3]), run(ch, 'forwarded', c[2], c[3])
        local what = ('%s (typed) vs %s (forwarded)'):format(c[1], c[2])
        ok(fwd.mirror_current, what .. ': focus stayed in the forwarder')
        eq(typed.row, fwd.row, what .. ': the same row')
        eq(fwd.row, fwd.published, what .. ': the forwarded move was PUBLISHED')
        eq(typed.node, fwd.node, what)
        eq(typed.context, fwd.context, what .. ': the hover preview followed')
        eq(typed.highlight, fwd.highlight, what .. ': the highlight followed')
        eq(1, fwd.pubs, what .. ': one publication')
        eq(0, fwd.cm, what .. ': NO CursorMoved of the pane\'s own — the move is published, not emitted (CART-2103)')
        -- (not just equal: a file-level node row's hover preview IS that node — typed and forwarded agreeing on a
        -- STALE preview would pass every check above)
        if fwd.node ~= vim.NIL then hovered = hovered + 1; eq(fwd.node, fwd.context, what .. ': the preview is the row') end
    end
    ok(hovered >= 2, 'the search and j land on node rows (G and gg on the header / footer): ' .. hovered)
    -- gg from the start row is no move: nothing to publish
    local still = run(ch, 'forwarded', '<F6>')
    eq(0, still.pubs, 'a forwarded key that does not move publishes nothing')
    -- and a pair: j then k forwarded back
    vim.rpcrequest(ch, 'nvim_exec_lua', 'T.start(...)', { 'forwarded', 1 })
    vim.wait(150, function () return false end, 10)
    vim.rpcrequest(ch, 'nvim_exec_lua', 'T.focus()', {})
    vim.rpcrequest(ch, 'nvim_input', '<F8><F8><F9>')
    vim.wait(250, function () return false end, 10)
    local s = vim.rpcrequest(ch, 'nvim_exec_lua', 'return T.snap()', {})
    eq(s.row, s.published, 'j j k forwarded: the published row is where the cursor ended')
    vim.fn.jobstop(ch); vim.fn.delete(root, 'rf'); vim.fn.delete(xdg, 'rf')
end)

test('list cursor: TYPED motion is delivered by nvim alone — the pane adds no CursorMoved and publishes once (CART-2098)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = fixture()
    local ch, xdg = child(root)
    for _, c in ipairs({ { 'j' }, { 'G' }, { 'gg', -1 }, { '/M.gamma<CR>' } }) do
        local keys = c[1]
        local s = run(ch, 'typed', keys, c[2])
        eq(1, s.cm, keys .. ': nvim\'s one CursorMoved, nothing of the pane\'s')
        eq(1, s.pubs, keys .. ': one publication')
        eq(s.row, s.published, keys)
    end
    vim.fn.jobstop(ch); vim.fn.delete(root, 'rf'); vim.fn.delete(xdg, 'rf')
end)
