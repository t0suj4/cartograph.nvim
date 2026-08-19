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

test('nav: the detail lens shows args/conditions/reads and rides the trail', function ()
    if not pcall(vim.treesitter.get_string_parser, '', 'lua') then skip 'no lua parser' end
    local symbols = require 'cartograph.panes.symbols'
    local ts = require 'cartograph.providers.treesitter'
    local keys = require('cartograph.config').keys
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write('local M = {}\nlocal cfg = {}\nfunction M.f(x)\n  local y = M.g(x, cfg.width)\n'
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

    store.pivot(f.id); symbols.show('fn', f.id)
    press(keys.cycle) -- statements -> detail
    eq('detail', symbols.view.lens)
    local kinds = {}
    for r = 1, vim.api.nvim_buf_line_count(symbols.buf) do
        local d = symbols.line_detail[r]
        if d then kinds[d.kind] = true end
    end
    ok(kinds.arg and kinds.cond and kinds.var, 'detail rows: arguments, condition, var read')

    -- the → var rows are MODULE reads only: a param/local the fn shadows (x, y)
    -- must NOT appear (else descending it would open a global's usages)
    for r = 1, vim.api.nvim_buf_line_count(symbols.buf) do
        local d = symbols.line_detail[r]
        if d and d.kind == 'var' then
            local nm = store.node(d.id) and store.node(d.id).name
            ok(nm ~= 'x' and nm ~= 'y', 'a shadowed local is not shown as a module var (' .. tostring(nm) .. ')')
        end
    end

    -- descend an argument -> the block lens on that element (lens reset to default)
    for r = 1, vim.api.nvim_buf_line_count(symbols.buf) do
        if symbols.line_detail[r] and symbols.line_detail[r].kind == 'arg' then
            vim.api.nvim_win_set_cursor(wsym, { r, 2 }); break
        end
    end
    press(keys.descend)
    eq('block', symbols.view.level)
    ok(symbols.view.lens == nil, 'the descended view starts at its default lens')

    -- ascend -> the detail lens is restored from the trail
    press(keys.ascend)
    eq('fn', symbols.view.level)
    eq('detail', symbols.view.lens)

    -- the <C-o> jumplist ENTRY does NOT carry the lens (trail only): a jump lands
    -- at the altitude's default. Asserted on the entry store.pivot records, not on
    -- loc_provider.get() — the provider is shared with the callers that carry a
    -- position across a REBUILD (refresh, re-ingest, re-attach), where the user
    -- never moved and the lens MUST survive. Testing the mechanism instead of the
    -- intent is what let :CartographUndo silently drop you out of a lens.
    eq('detail', store.loc_provider.get().lens) -- the full location KEEPS it now

    -- position survives a lens switch: on an arg row, cycling to statements
    -- ghost-anchors to the arg's enclosing statement, and cycling BACK restores
    -- the exact arg row
    local argrow
    for r = 1, vim.api.nvim_buf_line_count(symbols.buf) do
        if symbols.line_detail[r] and symbols.line_detail[r].kind == 'arg' then argrow = r end
    end
    vim.api.nvim_win_set_cursor(wsym, { argrow, 2 })
    local argline = symbols.line_stmt[argrow]
    -- BACKWARD, because the fn lens set has three entries now (statements /
    -- detail / lints): the assertion is about the ghost round-trip, not about a
    -- two-element set, so the direction is what has to be explicit
    press(keys.cycle_back) -- detail -> statements: the arg is gone, ghost to its statement
    eq('statements', symbols.view.lens or 'statements')
    eq(argline, symbols.line_stmt[vim.api.nvim_win_get_cursor(wsym)[1]]) -- same statement line
    press(keys.cycle) -- back to detail: the arg row is restored exactly
    local back = vim.api.nvim_win_get_cursor(wsym)[1]
    ok(symbols.line_detail[back] and symbols.line_detail[back].kind == 'arg',
        'cycling back restored the arg row')

    -- cycling FOLLOWS the current position, not a stale one: move to the LAST
    -- detail row, cycle to statements -> it lands on THAT statement's line
    -- (regression: a stale per-lens memory jumped back to an earlier row)
    local last = vim.api.nvim_buf_line_count(symbols.buf)
    vim.api.nvim_win_set_cursor(wsym, { last, 2 })
    local lastline = symbols.line_stmt[last]
    press(keys.cycle_back) -- detail -> statements
    eq(lastline, symbols.line_stmt[vim.api.nvim_win_get_cursor(wsym)[1]])
    press(keys.cycle) -- back to detail

    -- a var read in two statements (M here) shares a tag; the round-trip must
    -- restore the OCCURRENCE we were on, not the first with that tag
    local vrows = {}
    for r = 1, vim.api.nvim_buf_line_count(symbols.buf) do
        local d = symbols.line_detail[r]
        if d and d.kind == 'var' then vrows[#vrows + 1] = r end
    end
    if #vrows >= 2 then
        local later = vrows[#vrows] -- a later occurrence (different statement line)
        local lline = symbols.line_stmt[later]
        vim.api.nvim_win_set_cursor(wsym, { later, 2 })
        press(keys.cycle_back); press(keys.cycle) -- statements and back
        local b = vim.api.nvim_win_get_cursor(wsym)[1]
        ok(symbols.line_detail[b] and symbols.line_detail[b].kind == 'var'
            and symbols.line_stmt[b] == lline,
            'the round-trip restored the var occurrence we were on, not a namesake')
    end

    vim.cmd('tabclose')
    vim.fn.delete(root, 'rf')
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
