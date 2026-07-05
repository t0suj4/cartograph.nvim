-- Navigation: focus history (vim-jumplist semantics over pivots) and the
-- source pane's <C-]> jump resolution.

local store  = require 'cartograph.store'
local source = require 'cartograph.panes.source'

local function node(id, name, file, l1, l2)
    return { id = id, name = name, kind = 'function', file = file or 'm.lua',
        range = { start = { line = l1 or 0, char = 0 }, ['end'] = { line = l2 or 0, char = 0 } },
        order = 0 }
end

local function graph(nodes, edges)
    store.ingest({ schema = 1, root = '/x', nodes = nodes, edges = edges or {} })
end

-- ── focus history ───────────────────────────────────────────────────────────

test('nav: pivot records, back returns, forward re-returns', function ()
    graph({ node('a', 'a'), node('b', 'b'), node('c', 'c') })
    store.set_focus('a')
    store.pivot('b')
    store.pivot('c')
    store.back();    eq('b', store.focused)
    store.back();    eq('a', store.focused)
    store.forward(); eq('b', store.focused)
end)

test('nav: back on empty history is a no-op', function ()
    graph({ node('a', 'a') })
    store.set_focus('a')
    store.back()
    eq('a', store.focused)
end)

test('nav: a pivot after going back clears the forward stack', function ()
    graph({ node('a', 'a'), node('b', 'b'), node('c', 'c') })
    store.set_focus('a')
    store.pivot('b')
    store.back()
    store.pivot('c')
    store.forward()
    eq('c', store.focused) -- nothing forward of c
end)

test('nav: scrolling (plain set_focus) between pivots does not record', function ()
    graph({ node('a', 'a'), node('b', 'b'), node('c', 'c'), node('d', 'd') })
    store.set_focus('a')
    store.pivot('b')
    store.set_focus('c')  -- scrolled here; no history entry
    store.pivot('d')
    store.back(); eq('c', store.focused) -- back = where the last pivot happened
    store.back(); eq('a', store.focused)
end)

test('nav: history restores the browser location, not just the focus', function ()
    graph({ node('a', 'a'), node('b', 'b') })
    local restored
    store.loc_provider = {
        get = function () return { level = 'fn', fn = store.focused } end,
        set = function (loc) restored = loc end,
    }
    store.set_focus('a')
    store.pivot('b')       -- snapshots {level='fn', fn='a'}
    store.back()
    eq('a', store.focused)
    eq('fn', restored.level)
    eq('a', restored.fn)
    store.loc_provider = nil
end)

test('nav: ingest resets the history', function ()
    graph({ node('a', 'a'), node('b', 'b') })
    store.set_focus('a')
    store.pivot('b')
    graph({ node('a', 'a'), node('b', 'b') })
    store.back()
    eq('b', store.focused) -- unchanged: nothing to go back to
end)

test('nav: ascending back to a function view re-focuses it (source follows)', function ()
    -- descend focuses a callee; ascending back must re-sync the focused node to
    -- the view it lands on, or the source pane stays stranded on the callee and
    -- walking the caller's rows no longer refreshes it.
    local symbols = require 'cartograph.panes.symbols'
    graph({ node('caller', 'M.caller', 'm.lua', 6, 8),
        node('helper', 'M.helper', 'm.lua', 2, 4) },
        { { from = 'caller', to = 'helper', kind = 'ref',
            at = { { start = { line = 7, char = 9 }, ['end'] = { line = 7, char = 17 } } } } })

    -- wire both panes to real windows (attach installs the loc_provider + the
    -- focus-sync this test exercises)
    vim.cmd('tabnew')
    local wsrc = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsrc, source.create())
    source.attach(wsrc)
    vim.cmd('leftabove vsplit')
    local wsym = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsym, symbols.create())
    symbols.attach(wsym)

    symbols.show('file', 'm.lua')
    store.pivot('caller'); symbols.show('fn', 'caller')
    store.pivot('helper'); symbols.show('fn', 'helper')
    eq('M.helper', source.cur and source.cur.name) -- descent shows the callee

    -- ascend back to the caller's fn view via the loc provider (the path the
    -- h-key's restore_loc drives)
    store.loc_provider.set({ level = 'fn', fn = 'caller', row = 1 })
    eq('caller', store.focused)                    -- focus re-synced to the view
    eq('M.caller', source.cur and source.cur.name) -- and the source pane followed

    store.loc_provider = nil
    vim.cmd('tabclose')
end)

test('nav: ascend defers the source resync until the next move (peek up)', function ()
    local symbols = require 'cartograph.panes.symbols'
    local config  = require 'cartograph.config'
    config.sync_on_ascend = false
    graph({ node('caller', 'M.caller', 'm.lua', 6, 9),
        node('helper', 'M.helper', 'm.lua', 2, 4) },
        { { from = 'caller', to = 'helper', kind = 'ref',
            at = { { start = { line = 7, char = 9 }, ['end'] = { line = 7, char = 17 } } } } })
    vim.cmd('tabnew')
    local wsrc = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsrc, source.create()); source.attach(wsrc)
    vim.cmd('leftabove vsplit')
    local wsym = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsym, symbols.create()); symbols.attach(wsym)

    -- stand at fn-caller, then descend into helper (records the trail entry)
    store.pivot('caller'); symbols.show('fn', 'caller')
    store.pivot('helper'); symbols.show('fn', 'helper')
    symbols.trail = { { level = 'fn', fn = 'caller', row = 1 } } -- as descend recorded
    eq('M.helper', source.cur and source.cur.name)

    -- ascend (h) via the real mapping callback (feedkeys is flaky headless)
    local cb
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(symbols.buf, 'n')) do
        if m.lhs == config.keys.ascend then cb = m.callback end
    end
    ok(cb, 'ascend mapping present')
    cb()
    -- the peek: view is back at the caller, but the def pane still shows the
    -- callee, and a resync is armed for the next move
    eq('caller', symbols.view.fn)
    eq('M.helper', source.cur and source.cur.name)
    ok(symbols.view and symbols._resync ~= nil, 'resync armed, not yet fired')

    -- move off the landing row -> the def pane commits to the caller
    pcall(vim.api.nvim_win_set_cursor, wsym, { 2, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = symbols.buf })
    vim.wait(150)
    eq('caller', store.focused)
    eq('M.caller', source.cur and source.cur.name)
    ok(symbols._resync == nil, 'resync consumed')

    vim.cmd('tabclose')
end)

test('nav: sync_on_ascend = true resyncs the source pane immediately', function ()
    local symbols = require 'cartograph.panes.symbols'
    local config  = require 'cartograph.config'
    config.sync_on_ascend = true
    graph({ node('caller', 'M.caller', 'm.lua', 6, 9),
        node('helper', 'M.helper', 'm.lua', 2, 4) },
        { { from = 'caller', to = 'helper', kind = 'ref' } })
    vim.cmd('tabnew')
    local wsrc = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsrc, source.create()); source.attach(wsrc)
    vim.cmd('leftabove vsplit')
    local wsym = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsym, symbols.create()); symbols.attach(wsym)

    store.pivot('caller'); symbols.show('fn', 'caller')
    store.pivot('helper'); symbols.show('fn', 'helper')
    symbols.trail = { { level = 'fn', fn = 'caller', row = 1 } }
    local cb
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(symbols.buf, 'n')) do
        if m.lhs == config.keys.ascend then cb = m.callback end
    end
    cb()
    eq('caller', store.focused)                    -- no peek: synced at once
    eq('M.caller', source.cur and source.cur.name)
    ok(symbols._resync == nil, 'no deferred resync armed')

    config.sync_on_ascend = false -- restore the default for later tests
    vim.cmd('tabclose')
end)

test('nav: descend a compound statement into its inner forms (body view)', function ()
    if not pcall(vim.treesitter.get_string_parser, '', 'lua') then skip 'no lua parser' end
    local symbols = require 'cartograph.panes.symbols'
    local ts = require 'cartograph.providers.treesitter'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write('local M = {}\nfunction M.f(x)\n  if x then\n    M.g(x)\n    M.h(x)\n  end\nend\n'
        .. 'function M.g(x) return x end\nfunction M.h(x) return x end\nreturn M\n')
    fd:close()
    local data = ts.extract(root)
    store.ingest(data)
    vim.cmd('tabnew')
    local wsrc = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsrc, source.create()); source.attach(wsrc)
    vim.cmd('leftabove vsplit')
    local wsym = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsym, symbols.create()); symbols.attach(wsym)

    local f
    for _, n in ipairs(data.nodes) do if n.name == 'M.f' then f = n end end
    store.pivot(f.id); symbols.show('fn', f.id)

    -- the fn view collapses the whole `if` onto one statement row; descend it
    local cb
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(symbols.buf, 'n')) do
        if m.lhs == require('cartograph.config').keys.descend then cb = m.callback end
    end
    -- land on the (only) statement row, cursor ON a callee name in its
    -- flattened summary (bnw regression: that word must NOT be followed —
    -- the compound statement opens its block regardless of the word)
    for r = 1, vim.api.nvim_buf_line_count(symbols.buf) do
        if symbols.line_stmt[r] then
            local text = vim.api.nvim_buf_get_lines(symbols.buf, r - 1, r, false)[1]
            local col = text:find('%f[%w]g%f[%W]') -- a callee token in the row
            pcall(vim.api.nvim_win_set_cursor, wsym, { r, (col or 5) - 1 })
            break
        end
    end
    cb()
    eq('body', symbols.view.level) -- opened the block, did NOT dive into `g`
    -- the inner calls are now their own rows (callees resolve by tail name)
    local seen = {}
    for r = 1, vim.api.nvim_buf_line_count(symbols.buf) do
        local cs = symbols.line_calls[r]
        if cs and cs[1] then seen[cs[1].callee] = true end
    end
    ok(seen['g'] and seen['h'], 'the if-body calls became descendable rows')

    -- descend a leaf call row -> into that function
    for r = 1, vim.api.nvim_buf_line_count(symbols.buf) do
        local cs = symbols.line_calls[r]
        if cs and cs[1] and cs[1].callee == 'g' and cs[1].to then
            pcall(vim.api.nvim_win_set_cursor, wsym, { r, 0 }); cb(); break
        end
    end
    eq('fn', symbols.view.level)
    eq('M.g', store.node(symbols.view.fn).name)

    -- ascend back into the block: a block ascent stays in the SAME location,
    -- so it re-syncs the def pane IMMEDIATELY — no peek (which used to strand
    -- the pane on the callee while browsing the block)
    local acb
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(symbols.buf, 'n')) do
        if m.lhs == require('cartograph.config').keys.ascend then acb = m.callback end
    end
    acb()
    eq('body', symbols.view.level)
    eq('M.f', store.node(store.focused).name) -- focus back to the block's fn at once
    ok(symbols._resync == nil, 'no deferred peek armed for a block ascent')

    vim.cmd('tabclose')
    vim.fn.delete(root, 'rf')
end)

test('nav: hovering a caller with several call sites highlights them all', function ()
    if not pcall(vim.treesitter.get_string_parser, '', 'lua') then skip 'no lua parser' end
    local symbols = require 'cartograph.panes.symbols'
    -- caller calls helper TWICE (two occurrence ranges on one ref edge)
    graph({ node('helper', 'helper', 'm.lua', 1, 3), node('caller', 'caller', 'm.lua', 5, 10) },
        { { from = 'caller', to = 'helper', kind = 'ref', at = {
            { start = { line = 6, char = 4 }, ['end'] = { line = 6, char = 10 } },
            { start = { line = 8, char = 4 }, ['end'] = { line = 8, char = 10 } } } } })
    vim.cmd('tabnew')
    local wsrc = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsrc, source.create()); source.attach(wsrc)
    vim.cmd('leftabove vsplit')
    local wsym = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsym, symbols.create()); symbols.attach(wsym)

    symbols.show('callers', 'helper')
    local gr
    for r = 1, vim.api.nvim_buf_line_count(symbols.buf) do
        if symbols.line_group[r] then gr = r end
    end
    ok(gr, 'the caller folds into a group row (2 sites)')
    vim.api.nvim_set_current_win(wsym)
    pcall(vim.api.nvim_win_set_cursor, wsym, { gr, 2 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = symbols.buf })
    vim.wait(150)
    eq(2, #(store.context and store.context.ranges or {})) -- every occurrence
    eq('caller', store.node(store.context.node).name)

    vim.cmd('tabclose')
end)

-- ── <C-]> jump resolution ───────────────────────────────────────────────────

local function occ(l, c1, c2)
    return { start = { line = l, char = c1 }, ['end'] = { line = l, char = c2 } }
end

test('jump: an occurrence range under the cursor wins', function ()
    graph({ node('f', 'f', 'm.lua', 10, 20), node('g', 'M.helper'), node('h', 'other') },
        { { from = 'f', to = 'g', kind = 'ref', at = { occ(12, 4, 10) } },
          { from = 'f', to = 'h', kind = 'ref', at = { occ(15, 0, 5) } } })
    eq('g', source.resolve_jump(store.node('f'), 12, 6, ''))
    eq(nil, source.resolve_jump(store.node('f'), 12, 10, '')) -- past the range end
end)

test('jump: falls back to the cursor word (last path segment)', function ()
    graph({ node('f', 'f', 'm.lua', 10, 20), node('g', 'M.helper') },
        { { from = 'f', to = 'g', kind = 'ref', at = { occ(12, 4, 10) } } })
    eq('g', source.resolve_jump(store.node('f'), 13, 0, 'helper'))
end)

test('jump: an ambiguous word resolves to nothing', function ()
    graph({ node('f', 'f', 'm.lua', 10, 20), node('g', 'M.helper'), node('g2', 'x.helper') },
        { { from = 'f', to = 'g',  kind = 'ref' },
          { from = 'f', to = 'g2', kind = 'ref' } })
    eq(nil, source.resolve_jump(store.node('f'), 13, 0, 'helper'))
end)

test('jump: no uses edges -> nil', function ()
    graph({ node('f', 'f') })
    eq(nil, source.resolve_jump(store.node('f'), 0, 0, 'anything'))
end)
