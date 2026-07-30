-- THE MODE STRIP — "we have to show the user that there are different lenses
-- available". A lens you cannot discover is a lens you do not have: before this,
-- the only evidence that `fn` had three views was pressing <Tab> and watching the
-- pane change under you.
--
-- The rules under test are the honesty ones, because a strip that lies is worse
-- than no strip:
--   * TOTALITY. Every altitude answers. One that has a single view SAYS so — a
--     blank strip on 13 of 19 altitudes is the "absence rendered as silence"
--     defect wearing chrome, and it makes the strip's presence elsewhere
--     unreadable as information.
--   * ONE LIST. <Tab> and the strip read the same M.modes(), so the strip cannot
--     name a mode that does not cycle, nor omit one that does. Built on lens_set
--     alone it would have gone silent at `files`, where <Tab> plainly works.
--   * THE BUDGET LAW. The window is symbols_width wide however you draw in it. An
--     overlong strip must NOT tail-elide the list: a cut list of modes reads as
--     "these are all of them". It degrades to the active mode plus a COUNT.
--   * THE KEY IS REMAPPABLE. The ⇥ glyph is a courtesy for the default; a
--     remapped key prints literally rather than being drawn as a Tab it is not.

local symbols = require 'cartograph.panes.symbols'
local store   = require 'cartograph.store'
local config  = require 'cartograph.config'

-- the winbar is statusline syntax; this is what a user actually SEES
local function plain(s)
    s = s:gsub('%%#[^#]*#', ''):gsub('%%%*', '')
    return (s:gsub('%%%%', '%%'))
end

local function bar(level, lens)
    symbols.view = { level = level, lens = lens }
    return plain(symbols.winbar())
end

--- Every altitude symbols.lua dispatches on, read out of the module under test
--- the same way tools/navaudit.lua does it — so the roster cannot drift from the
--- code by a spec forgetting to grow.
local function altitudes()
    local src = debug.getinfo(symbols.render, 'S').source:sub(2)
    local text = table.concat(vim.fn.readfile(src), '\n')
    local out = {}
    for lvl in text:gmatch("level == '([a-z]+)'") do out[lvl] = true end
    out.fn = true -- the dispatch's else branch, named in no comparison
    return out
end

local function restore()
    config.symbols_width = 30
    config.keys.cycle = '<Tab>'
    symbols.view = { level = 'files' }
    symbols.files_mode = 'flat'
end


-- ── one list, published and cycled ───────────────────────────────────────────

test('modes: the fn altitude publishes its three lenses, active first by default',
    function ()
    restore()
    symbols.view = { level = 'fn' }
    local set, active = symbols.modes()
    eq({ 'statements', 'detail', 'lints' }, set)
    eq('statements', active, 'no explicit lens = the altitude default')
    symbols.view = { level = 'fn', lens = 'lints' }
    local _, act2 = symbols.modes()
    eq('lints', act2)
end)

test('modes: the files altitude answers with its DISPLAY modes, not nil', function ()
    restore()
    symbols.view = { level = 'files' }
    symbols.files_mode = 'tree'
    local set, active = symbols.modes()
    eq({ 'flat', 'tree' }, set, 'flat/tree is what <Tab> cycles here')
    eq('tree', active)
    restore()
end)

test('modes: an altitude with one view answers nil, not an empty list', function ()
    restore()
    symbols.view = { level = 'callers' }
    eq(nil, symbols.modes())
end)


-- ── totality: every altitude says something ──────────────────────────────────

test('strip: EVERY altitude renders a non-empty strip', function ()
    restore()
    local missing = {}
    for lvl in pairs(altitudes()) do
        local s = bar(lvl)
        if s == '' or s:match('^%s*$') then missing[#missing + 1] = lvl end
    end
    eq({}, missing, 'an altitude drawing blank chrome cannot be told from broken chrome')
    restore()
end)

test('strip: a single-view altitude SAYS it has one view', function ()
    restore()
    local s = bar('callers')
    ok(s:find('one view', 1, true), 'expected the absence stated, got ' .. vim.inspect(s))
    restore()
end)


-- ── the active mode is marked in TEXT, not by colour alone ───────────────────

test('strip: the active lens is bracketed and the others are named plainly',
    function ()
    restore()
    local s = bar('fn', 'detail')
    ok(s:find('[detail]', 1, true), 'the active lens is bracketed: ' .. s)
    ok(s:find('statements', 1, true), 'the other lenses are still named: ' .. s)
    ok(s:find('lints', 1, true), 'the other lenses are still named: ' .. s)
    ok(not s:find('[statements]', 1, true), 'only one is marked active: ' .. s)
    -- and the mark MOVES with the lens
    local t = bar('fn', 'lints')
    ok(t:find('[lints]', 1, true), t)
    ok(not t:find('[detail]', 1, true), t)
    restore()
end)

test('strip: the mark is text, so it survives a monochrome terminal', function ()
    restore()
    -- the highlight groups are an addition to the text, never the only signal
    local raw = symbols.winbar()
    ok(raw:find('%%#Cartograph'), 'expected highlight items: ' .. raw)
    eq(true, plain(raw) ~= raw, 'and stripping them leaves readable text')
    restore()
end)

test('strip: the files altitude shows flat/tree with the active one marked',
    function ()
    restore()
    symbols.view = { level = 'files' }
    symbols.files_mode = 'tree'
    local s = plain(symbols.winbar())
    ok(s:find('[tree]', 1, true), s)
    ok(s:find('flat', 1, true), s)
    restore()
end)


test('strip: the self provider\'s `live` lens is disclosed only where it exists',
    function ()
    restore()
    local saved = store.data
    store.data = { provider = 'disk', root = '/x' }
    symbols.view = { level = 'file', file = 'm.lua' }
    eq(nil, symbols.modes(), 'no runtime to ask: the file altitude has one view')
    store.data = { provider = 'self', root = 'self://' }
    local set, active = symbols.modes()
    eq({ 'members', 'live' }, set, 'the running instance adds a lens')
    eq('members', active)
    local s = plain(symbols.winbar())
    ok(s:find('live', 1, true), s)
    ok(vim.fn.strdisplaywidth(s) <= 30, 'and it fits: ' .. s)
    store.data = saved
    restore()
end)


-- ── the budget law ───────────────────────────────────────────────────────────

test('strip: fits symbols_width at EVERY altitude, in EVERY mode', function ()
    restore()
    local over = {}
    local function check(lvl, mode)
        local s = bar(lvl, mode)
        local w = vim.fn.strdisplaywidth(s)
        if w > 30 then
            over[#over + 1] = ('%s/%s = %d cols'):format(lvl, mode or '-', w)
        end
    end
    for lvl in pairs(altitudes()) do
        symbols.view = { level = lvl }
        local set = symbols.modes()
        if not set then
            check(lvl, nil) -- the "one view here" form is under the law too
        else
            for _, mode in ipairs(set) do check(lvl, mode) end
        end
    end
    eq({}, over, 'the strip is drawn in the same 30 columns as the rows')
    restore()
end)

test('strip: too narrow to list them all → the active one plus a COUNT', function ()
    restore()
    config.symbols_width = 14
    local s = bar('fn', 'statements')
    ok(s:find('+2', 1, true),
        'the withheld modes are COUNTED, never silently dropped: ' .. s)
    ok(not s:find('detail', 1, true), 'the list itself is gone, not truncated: ' .. s)
    ok(vim.fn.strdisplaywidth(s) <= 14, 'and it fits: ' .. s)
    restore()
end)

test('strip: squeezed further, the KEY hint goes before the count does', function ()
    restore()
    config.symbols_width = 14
    local wide = bar('fn', 'statements')
    config.symbols_width = 12
    local tight = bar('fn', 'statements')
    ok(tight:find('+2', 1, true), 'the count is the last thing to go: ' .. tight)
    ok(vim.fn.strdisplaywidth(tight) <= 12, 'and it still fits: ' .. tight)
    ok(#tight <= #wide, 'the tighter budget did not grow the strip')
    restore()
end)


-- ── the key is remappable ────────────────────────────────────────────────────

test('strip: the default <Tab> draws as ⇥', function ()
    restore()
    local s = bar('fn', 'statements')
    ok(s:find('⇥', 1, true), 'expected the Tab glyph: ' .. s)
    restore()
end)

test('strip: a REMAPPED cycle key prints literally, not as a Tab it is not',
    function ()
    restore()
    config.keys.cycle = '<C-n>'
    local s = bar('fn', 'statements')
    ok(s:find('<C-n>', 1, true), 'expected the real binding: ' .. s)
    ok(not s:find('⇥', 1, true), 'and not the default glyph: ' .. s)
    restore()
end)

test('strip: an UNBOUND cycle key names no key at all', function ()
    restore()
    config.keys.cycle = false
    local s = bar('fn', 'detail')
    ok(s:find('[detail]', 1, true), 'the lenses are still listed: ' .. s)
    ok(not s:find('⇥', 1, true), 'but nothing claims a key: ' .. s)
    restore()
end)

test('strip: a % in a binding is escaped, not read as a statusline item',
    function ()
    restore()
    config.keys.cycle = '<C-%>'
    symbols.view = { level = 'fn', lens = 'detail' }
    local raw = symbols.winbar()
    ok(raw:find('<C-%%>', 1, true), 'expected the percent doubled: ' .. raw)
    eq(true, plain(raw):find('<C-%>', 1, true) ~= nil, 'and it reads back literally')
    restore()
end)


-- ── the helpdoc's table is the same table ────────────────────────────────────

--- The lens table in doc/cartograph.txt, parsed. The helpdoc is the surface
--- nobody re-reads, so it drifts fastest (tools/docaudit.lua exists for exactly
--- this reason); the lens sets are small enough that BOTH directions are cheap
--- to check, so an undocumented lens fails here and so does a documented one
--- that no longer exists.
local function doc_table()
    local src = debug.getinfo(symbols.render, 'S').source:sub(2)
    local doc = src:gsub('lua/cartograph/panes/symbols%.lua$', 'doc/cartograph.txt')
    local out, inside = {}, false
    for _, line in ipairs(vim.fn.readfile(doc)) do
        if line:match('^%s+altitude%s+lenses%s*~%s*$') then
            inside = true
        elseif inside then
            if line:match('^%s*$') then break end
            local lvl, rest = line:match('^  (%S+)%s+(.+)$')
            if lvl then out[lvl] = vim.split(vim.trim(rest), '%s+') end
        end
    end
    return out
end

test('doc: the helpdoc lists exactly the lenses each altitude has', function ()
    restore()
    local documented = doc_table()
    ok(next(documented), 'the lens table was found in doc/cartograph.txt')

    local saved = store.data
    local function real(lvl)
        -- `file` gains `live` only under the self provider, so ASK it as self:
        -- the doc claims the lens exists, and this is where it exists
        store.data = { provider = lvl == 'file' and 'self' or 'disk', root = '/x' }
        symbols.view = { level = lvl, file = 'm.lua' }
        return symbols.modes()
    end

    for lvl, lenses in pairs(documented) do
        eq(lenses, real(lvl), 'doc/cartograph.txt claims these lenses for ' .. lvl)
    end
    -- and the other direction: no altitude has a lens the doc never mentions
    local undocumented = {}
    for lvl in pairs(altitudes()) do
        if not documented[lvl] and real(lvl) then
            undocumented[#undocumented + 1] = lvl
        end
    end
    eq({}, undocumented, 'an altitude with lenses the helpdoc never names')

    store.data = saved
    restore()
end)


-- ── it reaches the window ────────────────────────────────────────────────────

test('strip: render() paints the winbar on the pane window', function ()
    restore()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    write(root, 'm.lua', {
        'local function build(list)',
        '\tlocal s = ""',
        '\tfor _, x in ipairs(list) do s = s .. x end',
        '\treturn s',
        'end',
        'return build',
    })
    local data = require('cartograph.providers.treesitter').extract(root, {})
    store.ingest(data)
    local fn_id
    for _, n in ipairs(data.nodes) do if n.name == 'build' then fn_id = n.id end end
    ok(fn_id, 'the fixture fn was extracted')

    local buf = vim.api.nvim_create_buf(false, true)
    symbols.buf = buf
    vim.cmd('vsplit')
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    symbols.win = win

    symbols.view = { level = 'fn', fn = fn_id, lens = 'lints' }
    symbols.render()
    local painted = plain(vim.wo[win].winbar)
    ok(painted:find('[lints]', 1, true),
        'the window carries the strip for the lens it is showing: ' .. painted)

    -- and it FOLLOWS the lens, rather than being set once at attach
    symbols.view = { level = 'fn', fn = fn_id, lens = 'detail' }
    symbols.render()
    eq(true, plain(vim.wo[win].winbar):find('[detail]', 1, true) ~= nil,
        'the strip re-derives on every render')

    vim.api.nvim_win_close(win, true)
    symbols.win = nil
    restore()
end)

test('strip: a window showing someone else\'s buffer is never painted', function ()
    restore()
    local mine = vim.api.nvim_create_buf(false, true)
    local theirs = vim.api.nvim_create_buf(false, true)
    symbols.buf = mine
    vim.cmd('vsplit')
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, theirs)
    symbols.win = win
    vim.wo[win].winbar = ''
    symbols.view = { level = 'files' }
    symbols.render()
    eq('', vim.wo[win].winbar, 'the winbar is window-local: not ours to write')
    vim.api.nvim_win_close(win, true)
    symbols.win = nil
    restore()
end)
