-- THE WIDTH GATE. The symbols pane has `config.symbols_width` columns of text and
-- no more — `wrap` is off, so nvim clips a longer row with NO marker and the pane
-- silently withholds what it rendered. Measured on a real project before any of
-- this existed: 28 of 35 file rows clipped at 30 columns, and the per-file symbol
-- COUNT was the first casualty because it sits at the far right of the row.
--
-- THE BUDGET LAW (user, [[cartograph-concern-layering]]): "if it cannot fit within
-- that budget, it's probably detail better to be shown somewhere else or a place
-- to descend into." So a row carries ONE identity that FITS, and this spec is the
-- fence for it. The 5 pre-existing pane specs assert what a row SAYS; none assert
-- that a row can be SEEN.

local store   = require 'cartograph.store'
local symbols = require 'cartograph.panes.symbols'
local config  = require 'cartograph.config'

local function R(l1, l2)
    return { start = { line = l1, char = 0 }, ['end'] = { line = l2 or l1, char = 0 } }
end
local function mod(file)
    return { id = file, name = file, kind = 'module', file = file, range = R(0), order = 0 }
end
local function fn(id, name, file, l1)
    return { id = id, name = name, kind = 'function', file = file,
        range = R(l1 or 1), order = l1 or 1 }
end

--- Render a level into the real pane buffer and hand back its lines.
local function render(level, ctx_val)
    symbols.buf = nil
    symbols.create()
    symbols.show(level, ctx_val)
    return vim.api.nvim_buf_get_lines(symbols.buf, 0, -1, false)
end

local function widest(lines)
    local w, worst = 0, nil
    for _, l in ipairs(lines) do
        local lw = vim.fn.strdisplaywidth(l)
        if lw > w then w, worst = lw, l end
    end
    return w, worst
end

-- A tree with the three shapes that break naive rendering: a deep path, a
-- basename SHARED by two directories (Von-Neumann really has two railbot.lua),
-- and a basename longer than the whole budget.
local DEEP  = 'prototypes/entity/crash-site-assembling-machine.lua'
local RB1   = 'prototypes/entity/railbot.lua'
local RB2   = 'scenarios/vonNeumann/railbot.lua'
local SHORT = 'data.lua'
local function tree()
    store.ingest({ schema = 1, root = '/x', edges = {}, nodes = {
        mod(SHORT), mod(DEEP), mod(RB1), mod(RB2),
        fn('f1', 'build_it', DEEP, 3), fn('f2', 'tick', RB1, 4),
        fn('f3', 'spawn', RB2, 5), fn('f4', 'main', SHORT, 6),
    } })
end

-- ── the budget is DECLARED, not hardcoded ───────────────────────────────────

test('width: the budget is a config field, and the renderers honour it',
    function ()
    eq(30, config.symbols_width)   -- the user's actual pane; the default IS the law
    tree()
    local w = widest(render('files'))
    ok(w <= 30, 'at the default budget every file row fits, widest = ' .. w)
    config.symbols_width = 20
    local narrow = widest(render('files'))
    ok(narrow <= 20, 'and at 20 they fit 20, widest = ' .. narrow)
    ok(narrow < w, 'the rows actually got narrower: ' .. narrow .. ' < ' .. w)
    config.symbols_width = 30
end)

-- ── identity fits, and stays UNAMBIGUOUS ────────────────────────────────────

test('width: every file row fits the budget at every files mode', function ()
    tree()
    for _, mode in ipairs({ 'flat', 'tree' }) do
        symbols.files_mode = mode
        local lines = render('files')
        local w, worst = widest(lines)
        ok(w <= 30, ('%s mode: widest row = %d — %s'):format(mode, w, tostring(worst)))
    end
    symbols.files_mode = 'flat'
end)

test('width: a SHARED basename keeps the parent that separates it', function ()
    -- the failure this prevents: two rows both reading `railbot.lua`, or twelve
    -- reading `init.lua`. Dropping the prefix is allowed; ambiguity is not.
    tree()
    local lines = render('files')
    local hits = {}
    for _, l in ipairs(lines) do
        if l:find('railbot', 1, true) then hits[#hits + 1] = l end
    end
    eq(2, #hits)
    ok(hits[1] ~= hits[2], 'the two railbot rows are distinguishable: '
        .. table.concat(hits, ' | '))
    ok(hits[1]:find('entity') or hits[2]:find('entity'),
        'and the separating parent is what was kept: ' .. table.concat(hits, ' | '))
end)

test('width: a UNIQUE basename drops its prefix entirely', function ()
    tree()
    local lines = render('files')
    local found
    for _, l in ipairs(lines) do if l:find('machine', 1, true) then found = l end end
    ok(found, 'the deep file has a row')
    ok(not found:find('prototypes', 1, true),
        'the directory prefix is gone (it is detail): ' .. found)
    ok(found:find('%(1%)'), 'and the COUNT survived — it is what the roster is scanned for: '
        .. found)
end)

test('width: an over-budget identity elides with a MARK, never silently',
    function ()
    tree()
    local lines = render('files')
    local found
    for _, l in ipairs(lines) do if l:find('machine', 1, true) then found = l end end
    -- `crash-site-assembling-machine.lua` is 33 cols; the budget is 30 with a
    -- 5-col count, so it MUST lose characters — and must say so
    ok(found:find('…'), 'the elision is marked: ' .. found)
    ok(found:find('^crash%-site'), 'the head is kept: ' .. found)
    ok(found:find('lua'), 'and so is the tail (both ends carry signal): ' .. found)
end)

test('width: the full path is never LOST — line_file keeps it', function ()
    -- the label is for the eye; every consumer (hover, gf, staging, the source
    -- pane) reads line_file, so shortening a row must not shorten a path
    tree()
    render('files')
    local paths = {}
    for _, f in pairs(symbols.line_file) do paths[f] = true end
    ok(paths[DEEP], 'the deep path is intact behind its row')
    ok(paths[RB1] and paths[RB2], 'both railbot paths are intact')
end)

-- ── the disclosure home: descend ────────────────────────────────────────────

test('width: descending a file DISCLOSES the directory it dropped', function ()
    -- the law says overflow goes somewhere else or behind a descend. This is the
    -- descend: a dim breadcrumb above the header, only when something was dropped.
    tree()
    local lines = render('file', DEEP)
    ok(lines[1]:find('prototypes/entity'), 'the dropped prefix is here: ' .. lines[1])
    ok(lines[2]:find('machine'), 'above the file itself: ' .. tostring(lines[2]))
    local w = widest(lines)
    ok(w <= 30, 'and the breadcrumb obeys the budget too, widest = ' .. w)
    -- a root file dropped nothing, so it gets no breadcrumb (no empty chrome)
    local flat = render('file', SHORT)
    ok(flat[1]:find('data%.lua'), 'a root file has no breadcrumb: ' .. flat[1])
end)

test('width: the file header still maps to its row after a breadcrumb', function ()
    -- the header row is no longer row 1 when a breadcrumb precedes it; anything
    -- reading file_header (the move destination marker) must follow it
    tree()
    render('file', DEEP)
    eq(2, symbols.file_header[DEEP])
    render('file', SHORT)
    eq(1, symbols.file_header[SHORT])
end)

-- ── the ratchet for what does NOT fit yet ────────────────────────────────────

test('width: PROSE rows are the known overflow class, and it does not grow',
    function ()
    -- Notes and empty-state sentences ("(no callers found — entry point, or
    -- dynamically dispatched)") are prose, not identities: they cannot fit 30
    -- columns and shrinking a name to make room would be the worse trade. They
    -- are DEBT with a home already designed (hover / virt_lines), so this counts
    -- them and refuses growth rather than pretending the pane is clean.
    tree()
    local over = 0
    for _, level in ipairs({ 'files', 'ws' }) do
        for _, l in ipairs(render(level)) do
            if vim.fn.strdisplaywidth(l) > 30 then over = over + 1 end
        end
    end
    eq(1, over) -- the ws empty note: "(empty — 'm' on a symbol marks it)"
end)
