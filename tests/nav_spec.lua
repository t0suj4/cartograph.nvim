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

test('nav: a JUMPLIST entry omits the lens, but the location itself keeps it',
    function ()
    -- The policy split that :CartographUndo exposed. A jump lands at the
    -- altitude's default lens, so store.pivot strips it from its entry. But the
    -- SAME provider is what refresh/init/re-attach use to carry a position across
    -- a rebuild, where the user never moved — stripping inside the provider applied
    -- the jumplist's policy to all of them, and undo dropped you out of `lints`.
    graph({ node('a', 'a'), node('b', 'b') })
    store.loc_provider = {
        get = function () return { level = 'fn', fn = store.focused, lens = 'lints' } end,
        set = function () end,
    }
    store.set_focus('a')
    store.pivot('b')
    eq('lints', store.loc_provider.get().lens)          -- the location keeps it
    eq(nil, store._nav_back[#store._nav_back].loc.lens) -- the JUMP entry does not
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

-- the PEEK is opt-in since CART-0473 (`sync_on_ascend = false`): ascending used to
-- keep the descended body on screen until the first j/k, and living with it said the
-- panes disagreeing for one keystroke costs more than the re-render it saves.
test('nav: with sync_on_ascend = false, ascend defers the resync (peek up)', function ()
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

    config.sync_on_ascend = true -- restore the DEFAULT for later tests
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

    config.sync_on_ascend = true -- (the default; this test set it explicitly anyway)
    vim.cmd('tabclose')
end)

test('nav: descend a compound statement into its inner forms (block view)', function ()
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
    eq('block', symbols.view.level) -- opened the block, did NOT dive into `g`
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
    eq('block', symbols.view.level)
    eq('M.f', store.node(store.focused).name) -- focus back to the block's fn at once
    ok(symbols._resync == nil, 'no deferred peek armed for a block ascent')

    vim.cmd('tabclose')
    vim.fn.delete(root, 'rf')
end)

-- REPORTED FROM THE BROWSER (mantis, auth_process_plain_password): descending
-- `$t_login_method = config_get_global( 'login_method' )` landed two lines down
-- on the `if` that REASSIGNS that local, instead of on config_get_global. The
-- word under the cursor is a row's own def, and the go-to-definition search,
-- finding none EARLIER, ran forward and took a later write. A definition is
-- never ahead of you.
test('nav: descending a row whose word it DEFINES follows the call, not a later write', function ()
    if not pcall(vim.treesitter.get_string_parser, '', 'lua') then skip 'no lua parser' end
    local symbols = require 'cartograph.panes.symbols'
    local ts = require 'cartograph.providers.treesitter'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write('local M = {}\nfunction M.f(x)\n  local v = M.g(x)\n  if x then\n    v = x\n  end\n'
        .. '  return v\nend\nfunction M.g(x) return x end\nreturn M\n')
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
    local cb
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(symbols.buf, 'n')) do
        if m.lhs == require('cartograph.config').keys.descend then cb = m.callback end
    end
    -- the FIRST statement row (`v ← g`), cursor on the name it defines — where
    -- the browser puts it, and the name the row leads with
    local target
    for r = 1, vim.api.nvim_buf_line_count(symbols.buf) do
        if symbols.line_stmtidx[r] == 1 then target = r break end
    end
    ok(target, 'the defining statement has a row')
    local text = vim.api.nvim_buf_get_lines(symbols.buf, target - 1, target, false)[1]
    local col = text:find('%f[%w]v%f[%W]')
    ok(col, 'the row leads with the local it defines')
    pcall(vim.api.nvim_win_set_cursor, wsym, { target, col - 1 })
    cb()
    -- RED before the fix: level stays 'fn' on M.f, cursor moved to the `if` row
    eq('fn', symbols.view.level)
    eq('M.g', store.node(symbols.view.fn).name)

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

test('nav: j/k step out of a block (sticky two-press) and back in', function ()
    if not pcall(vim.treesitter.get_string_parser, '', 'lua') then skip 'no lua parser' end
    local symbols = require 'cartograph.panes.symbols'
    local ts = require 'cartograph.providers.treesitter'
    local keys = require('cartograph.config').keys
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write('local M = {}\nfunction M.f(x)\n  if x then\n    M.g(x)\n    M.h(x)\n  end\n  M.after()\nend\n'
        .. 'function M.g(x) return x end\nfunction M.h(x) return x end\nfunction M.after() return 1 end\nreturn M\n')
    fd:close()
    local data = ts.extract(root); store.ingest(data)
    local f; for _, n in ipairs(data.nodes) do if n.name == 'M.f' then f = n end end
    vim.cmd('tabnew')
    local wsrc = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsrc, source.create()); source.attach(wsrc)
    vim.cmd('leftabove vsplit')
    local wsym = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsym, symbols.create()); symbols.attach(wsym)
    local K = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(symbols.buf, 'n')) do K[m.lhs] = m.callback end
    local function press(k) vim.api.nvim_set_current_win(wsym); K[k]() end

    store.pivot(f.id); symbols.show('fn', f.id)
    for r = 1, vim.api.nvim_buf_line_count(symbols.buf) do
        if symbols.line_stmt[r] == 3 then vim.api.nvim_win_set_cursor(wsym, { r, 2 }) end
    end
    press(keys.descend); eq('block', symbols.view.level)
    press(keys.down)                          -- move to the last form
    press(keys.down)                          -- j at the edge: step OUT
    eq('fn', symbols.view.level)              -- landed in the parent function
    ok(symbols._stepout ~= nil, 'step-out is provisional (remembered)')

    press(keys.up)                            -- opposite key: back INTO the block
    eq('block', symbols.view.level)
    ok(symbols._stepout == nil, 'return cleared the memory')

    press(keys.down)                          -- step out again
    ok(symbols._stepout ~= nil, 'provisional again')
    press(keys.ascend)                        -- h while provisional: also returns in
    eq('block', symbols.view.level)
    ok(symbols._stepout == nil, 'h consumed the provisional step-out')

    press(keys.down)                          -- step out once more
    press(keys.down)                          -- SAME key again: commit
    eq('fn', symbols.view.level)
    ok(symbols._stepout == nil, 'the second j committed to the parent')

    vim.cmd('tabclose')
    vim.fn.delete(root, 'rf')
end)

test('nav: stepping down from a block at the function edge is a no-op', function ()
    if not pcall(vim.treesitter.get_string_parser, '', 'lua') then skip 'no lua parser' end
    local symbols = require 'cartograph.panes.symbols'
    local ts = require 'cartograph.providers.treesitter'
    local keys = require('cartograph.config').keys
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    -- the if is the LAST (only) statement: there is nowhere below to go
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write('local M = {}\nfunction M.f(x)\n  if x then\n    M.g(x)\n  end\nend\n'
        .. 'function M.g(x) return x end\nreturn M\n')
    fd:close()
    local data = ts.extract(root); store.ingest(data)
    local f; for _, n in ipairs(data.nodes) do if n.name == 'M.f' then f = n end end
    vim.cmd('tabnew')
    local wsrc = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsrc, source.create()); source.attach(wsrc)
    vim.cmd('leftabove vsplit')
    local wsym = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsym, symbols.create()); symbols.attach(wsym)
    local K = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(symbols.buf, 'n')) do K[m.lhs] = m.callback end

    store.pivot(f.id); symbols.show('fn', f.id)
    for r = 1, vim.api.nvim_buf_line_count(symbols.buf) do
        if symbols.line_stmt[r] == 3 then vim.api.nvim_win_set_cursor(wsym, { r, 2 }) end
    end
    vim.api.nvim_set_current_win(wsym)
    K[keys.descend]()
    eq('block', symbols.view.level)
    local before = vim.api.nvim_win_get_cursor(wsym)[1]
    K[keys.down]() -- nowhere below without leaving the function -> no-op
    eq('block', symbols.view.level)
    eq(before, vim.api.nvim_win_get_cursor(wsym)[1]) -- stayed put
    ok(symbols._stepout == nil, 'no provisional step-out was armed')

    vim.cmd('tabclose')
    vim.fn.delete(root, 'rf')
end)

test('nav: h after a block step-out returns through the caller list it came from', function ()
    if not pcall(vim.treesitter.get_string_parser, '', 'lua') then skip 'no lua parser' end
    local symbols = require 'cartograph.panes.symbols'
    local ts = require 'cartograph.providers.treesitter'
    local keys = require('cartograph.config').keys
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    -- C calls X inside an if; C has a statement after the if (so j lands)
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write('local M = {}\nfunction M.C(x)\n  if x then\n    M.X()\n  end\n  M.after()\nend\n'
        .. 'function M.X() end\nfunction M.after() end\nreturn M\n')
    fd:close()
    local data = ts.extract(root); store.ingest(data)
    local X; for _, n in ipairs(data.nodes) do if n.name == 'M.X' then X = n end end
    vim.cmd('tabnew')
    local wsrc = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsrc, source.create()); source.attach(wsrc)
    vim.cmd('leftabove vsplit')
    local wsym = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsym, symbols.create()); symbols.attach(wsym)
    local K = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(symbols.buf, 'n')) do K[m.lhs] = m.callback end
    local function press(k) vim.api.nvim_set_current_win(wsym); K[k]() end

    store.pivot(X.id); symbols.show('callers', X.id)
    eq('callers', symbols.view.level)
    -- descend the caller (M.C) into its function, then into the if block
    for r = 1, vim.api.nvim_buf_line_count(symbols.buf) do
        if symbols.line_site[r] or symbols.line_group[r] then
            vim.api.nvim_win_set_cursor(wsym, { r, 2 }) break
        end
    end
    press(keys.descend); eq('fn', symbols.view.level)
    for r = 1, vim.api.nvim_buf_line_count(symbols.buf) do
        local t = vim.api.nvim_buf_get_lines(symbols.buf, r - 1, r, false)[1]
        if symbols.line_stmt[r] and t:match('X') then vim.api.nvim_win_set_cursor(wsym, { r, 2 }) break end
    end
    press(keys.descend); eq('block', symbols.view.level)

    press(keys.down)  -- j: step out to the function
    press(keys.down)  -- j: commit to the function
    eq('fn', symbols.view.level)
    -- h must retrace: function -> the caller list (not back into the block)
    press(keys.ascend); eq('callers', symbols.view.level)

    vim.cmd('tabclose')
    vim.fn.delete(root, 'rf')
end)

-- THE SYMBOLS LEVEL (CART-0472), which replaced the detail lens. A statement that
-- names more than one resolvable thing descends into its NAMES; j/k steps them and
-- steps out at the edges like a block; descend on a name goes to it. Two invariants
-- carried over from the lens this replaced: a local the function SHADOWS must not
-- show up as the module var of that name (resolution is by RANGE, so it cannot), and
-- ascending restores the lens you were in.
test('nav: a statement descends into its NAMES, and the trail comes back', function ()
    if not pcall(vim.treesitter.get_string_parser, '', 'lua') then skip 'no lua parser' end
    local symbols = require 'cartograph.panes.symbols'
    local ts = require 'cartograph.providers.treesitter'
    local keys = require('cartograph.config').keys
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write('local M = {}\nlocal cfg = {}\nfunction M.f(x)\n  local y = M.g(x, cfg)\n'
        .. '  if x > 0 then\n    M.h(y)\n  end\nend\n'
        .. 'function M.g(a, b) return a end\nfunction M.h(z) return z end\nreturn M\n')
    fd:close()
    local data = ts.extract(root); store.ingest(data)
    local f; for _, n in ipairs(data.nodes) do if n.name == 'M.f' then f = n end end
    vim.cmd('tabnew')
    local wsrc = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsrc, source.create()); source.attach(wsrc)
    vim.cmd('leftabove vsplit')
    local wsym = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(wsym, symbols.create()); symbols.attach(wsym)
    local K = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(symbols.buf, 'n')) do K[m.lhs] = m.callback end
    local function press(k) vim.api.nvim_set_current_win(wsym); K[k]() end

    store.set_focus(f.id); store.pivot(f.id); symbols.show('fn', f.id)
    -- the `local y = M.g(x, cfg)` row: cursor at column 0, so no cursor-word step
    -- claims it and the level is what the row offers
    local target
    for r = 1, vim.api.nvim_buf_line_count(symbols.buf) do
        if symbols.line_stmt[r] == 4 then target = r break end
    end
    ok(target, 'the statement has a row')
    vim.api.nvim_win_set_cursor(wsym, { target, 0 })
    press(keys.descend)
    eq('syms', symbols.view.level)

    local names, byname = {}, {}
    for r = 1, vim.api.nvim_buf_line_count(symbols.buf) do
        local it = symbols.line_syms[r]
        if it then names[#names + 1] = it.text; byname[it.text] = { row = r, it = it } end
    end
    ok(vim.tbl_contains(names, 'cfg'), 'the module var is a row: ' .. vim.inspect(names))
    ok(vim.tbl_contains(names, 'y'), 'so is the local it defines')
    -- a local the fn shadows resolves to NOTHING, so descending it can never open
    -- the module var of that name
    ok(not byname.y.it.id, 'a local has no node')
    ok(not (byname.x and byname.x.it.id), 'nor does a param')
    ok(byname.cfg.it.id and store.node(byname.cfg.it.id).name == 'cfg',
        'the module var resolves')

    -- ★ AND IT HIGHLIGHTS LIKE A STATEMENT DOES, one grain finer. Reported: "it
    -- doesn't highlight the same way statements do" -- syms was in the node-hover
    -- class, so hovering a resolved name TOOK OVER the source pane with the def it
    -- points at and threw the statement you were reading off the screen. A name row
    -- highlights its OWN COLUMNS; the header highlights the line.
    local hls = {}
    store.on_highlight(function (hl)
        if hl and hl.ranges and hl.ranges[1] then
            local rg = hl.ranges[1]
            hls[#hls + 1] = ('%d:%d-%d'):format(rg.start.line, rg.start.char, rg['end'].char)
        end
    end)
    local function hover(r)
        hls = {}
        vim.api.nvim_win_set_cursor(wsym, { r, 0 })
        vim.api.nvim_exec_autocmds('CursorMoved', { buffer = symbols.buf })
        vim.wait(120, function () return #hls > 0 end)
        return hls[#hls]
    end
    local hcfg = hover(byname.cfg.row)
    eq(('%d:%d-%d'):format(byname.cfg.it.sr, byname.cfg.it.sc, byname.cfg.it.ec), hcfg)
    ok(source.ctx == nil, 'a name row does not take the source pane over')

    -- j/k walks the names, and past the last one it steps OUT like a block does
    vim.api.nvim_win_set_cursor(wsym, { byname.cfg.row, 0 })
    press(keys.descend)
    eq('lit', symbols.view.level)          -- cfg carries table data
    press(keys.ascend)
    eq('syms', symbols.view.level, 'ascend returns to the names')
    press(keys.ascend)
    eq('fn', symbols.view.level, 'and then to the statement list')

    -- the trail restores the LENS you were in, not just the altitude
    press(keys.cycle)
    eq('lints', symbols.view.lens)
    vim.api.nvim_win_set_cursor(wsym, { 1, 0 })
    press(keys.cycle)
    eq('statements', symbols.view.lens, 'two lenses now, so cycle returns')

    vim.cmd('tabclose')
    vim.fn.delete(root, 'rf')
end)

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

-- THE ROW-LOCAL NAME PICK (CART-0471). The detail lens existed because there was
-- no way to reach a variable inside a call, and it answered a POSITION question
-- with a containment mechanism: a mode switch, a scan of indented rows, then a
-- descend. The pick asks the row instead. Two things this pins, both of which are
-- the reason it is cheap: the names come from the SPEC's declared mention types
-- (not a new table), and a name resolves BY RANGE off the use edges the graph
-- already carries -- which answers the shadowing question for free, since a local
-- simply has no use edge covering it.
test('pick: a row\'s names, resolved by range, labelled digits first', function ()
    if not pcall(vim.treesitter.get_string_parser, '', 'lua') then skip 'no lua parser' end
    local symbols = require 'cartograph.panes.symbols'
    local ts = require 'cartograph.providers.treesitter'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    -- a module var read INSIDE a call argument, beside a local of the same shape
    fd:write('local M = {}\nlocal cfg = { a = 1 }\nfunction M.f(x)\n  q(cfg, x + 1)\nend\n'
        .. 'function q(a, b) return a, b end\nreturn M\n')
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
    ok(f, 'the fixture has M.f')
    -- set_focus, not just pivot: the SOURCE pane renders on focus (a real descent
    -- goes through enter() -> browser_pivot, which does both), and labels can only
    -- land in a body the pane is actually showing.
    store.set_focus(f.id); store.pivot(f.id); symbols.show('fn', f.id)
    local target
    for r = 1, vim.api.nvim_buf_line_count(symbols.buf) do
        if symbols.line_stmt[r] == 4 then target = r break end -- the `q(cfg, x + 1)` line
    end
    ok(target, 'the call statement has a row')

    local items, file = symbols.pick_items(target)
    local texts = {}
    for _, it in ipairs(items) do texts[#texts + 1] = it.text end
    eq({ 'q', 'cfg', 'x' }, texts)               -- source order, mention types only
    eq(store.node(f.id).file, file)   -- the panes' spelling, not the abspath
    eq('1', items[1].label)                      -- digits first: same keys on dvorak
    eq('2', items[2].label)
    local by = {}
    for _, it in ipairs(items) do by[it.text] = it end
    ok(by.cfg.id and store.node(by.cfg.id), 'the module var resolves by range')
    eq('cfg', store.node(by.cfg.id).name)
    ok(not by.x.id, 'a PARAM has no module-var use edge covering it, so it stays unresolved')

    -- and the labels reach the source pane: the pane is showing M.f, so every
    -- position on this line lands. A pane showing something else must refuse.
    -- (pick_cursor drops a hover takeover before labelling for this reason; here
    -- the takeover is cleared directly, since the spec calls the channel itself.)
    store.set_context(nil)
    -- FIXTURE SETUP, not the thing under test: in a session the source pane renders
    -- on a focus crossing, and this spec's pane is created after the focus is already
    -- where it wants it. Render it directly so the assertions below are about the
    -- LABELS, not about pane wiring.
    source.render(f.id)
    eq(#items, store.set_labels({ file = file, items = items }))
    eq(0, store.set_labels({ file = '/nowhere.lua', items = items }))
    store.set_labels(nil)

    -- END TO END, the part pick_items cannot prove: press a label, land. `2` is
    -- `cfg` -- the module var read inside the call argument, which is the case the
    -- detail lens was built for and the reason this exists.
    vim.api.nvim_set_current_win(wsym)
    pcall(vim.api.nvim_win_set_cursor, wsym, { target, 0 })
    vim.api.nvim_feedkeys('2', 'n', false)
    symbols.pick_cursor()
    -- `cfg` carries table DATA, so it opens at its LITERAL altitude: the pick obeys
    -- the browser's own var_level rule rather than forcing `var`, or the same subject
    -- would land in two different places depending on how you reached it.
    eq('lit', symbols.view.level)
    eq('cfg', store.node(symbols.view.lit).name)

    -- ...AND THE SAME NAME BY THE BROWSER'S OWN VERB, no key of its own: `descend`
    -- with the cursor ON the word. The fn altitude has always resolved the cursor
    -- word (a callee, then a var); the block and region altitudes had NO word logic
    -- at all and took the row's first resolvable callee whatever the cursor was on.
    symbols.show('fn', f.id)
    local brow
    for r = 1, vim.api.nvim_buf_line_count(symbols.buf) do
        if symbols.line_stmt[r] == 4 then brow = r break end
    end
    local cb
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(symbols.buf, 'n')) do
        if m.lhs == require('cartograph.config').keys.descend then cb = m.callback end
    end
    -- into the statement's own forms first, so the row below is a BLOCK row
    local btext = vim.api.nvim_buf_get_lines(symbols.buf, brow - 1, brow, false)[1]
    local ccol = btext:find('cfg')
    ok(ccol, 'the row shows the name: ' .. tostring(btext))
    pcall(vim.api.nvim_win_set_cursor, wsym, { brow, ccol - 1 })
    cb()
    eq('lit', symbols.view.level)
    eq('cfg', store.node(symbols.view.lit).name)

    vim.cmd('tabclose')
    vim.fn.delete(root, 'rf')
end)
