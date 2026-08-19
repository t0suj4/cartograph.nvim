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
    for _, mode in ipairs({ 'flat', 'layers' }) do
        symbols.files_mode = mode
        local lines = render('files')
        local w, worst = widest(lines)
        ok(w <= 30, ('%s mode: widest row = %d — %s'):format(mode, w, tostring(worst)))
    end
    symbols.files_mode = 'flat'
end)

-- ── the LAYER roster: what replaced the include tree ────────────────────────
-- Reported from the browser: 524 files rendered 3353 rows, `/config_api.php`
-- matched 252 of them, and a 42-column indent left rows blank in a 30-column
-- pane. The measured cause was that a drawn tree's DEPTH is not a property of a
-- file (37% of mantis's files, 50% of ours, were drawn at more than one depth;
-- config_api.php at 23). These pin the three properties that fix made load-
-- bearing. RED before it: the old renderer expanded every root.

--- Two leaves, one layer above them, and a 3-file CYCLE — the shape a fixture
--- without cycles cannot fence at all. THE NAMES FIGHT THE LAYERING ON PURPOSE:
--- alphabetical order is the exact REVERSE of level order, so a test that passes
--- under the flat renderer is not testing this one. (Written after the first cut
--- of these specs stayed green with the layer roster stashed out.)
local function layered()
    local function imp(a, b) return { kind = 'import', from = a, to = b } end
    store.ingest({ schema = 1, root = '/x', nodes = {
        mod('z_leaf_a.lua'), mod('z_leaf_b.lua'), mod('m_mid.lua'),
        mod('a_ring1.lua'), mod('a_ring2.lua'), mod('a_ring3.lua'),
    }, edges = {
        imp('m_mid.lua', 'z_leaf_a.lua'), imp('m_mid.lua', 'z_leaf_b.lua'),
        imp('a_ring1.lua', 'a_ring2.lua'), imp('a_ring2.lua', 'a_ring3.lua'),
        imp('a_ring3.lua', 'a_ring1.lua'), imp('a_ring1.lua', 'm_mid.lua'),
    } })
end

test('layers: EVERY file appears EXACTLY once — `/` over the pane is a total search',
    function ()
    layered()
    symbols.files_mode = 'layers'
    local lines = render('files')
    local seen, dups = {}, {}
    for r = 1, #lines do
        local f = symbols.line_file[r]
        if f then
            if seen[f] then dups[#dups + 1] = f end
            seen[f] = true
        end
    end
    eq({}, dups)                        -- the old tree drew a shared file 5.9x on average
    eq(6, vim.tbl_count(seen))          -- and every file is still here
    -- 6 files + the one cycle announcement, and nothing else: the flat renderer
    -- would give exactly 6, so this row count is what makes the test discriminate
    eq(7, #lines)
    symbols.files_mode = 'flat'
end)

test('layers: level ASCENDS, so the roster reads as load order', function ()
    layered()
    symbols.files_mode = 'layers'
    local lines = render('files')
    local at = {}
    for r = 1, #lines do
        local f = symbols.line_file[r]
        if f then at[f] = r end
    end
    -- a leaf requires nobody, so it comes first; mid needs the leaves; the ring
    -- needs mid. Depth is the CONDENSED one: the three ring files share a level
    -- and so are adjacent, in any order among themselves.
    ok(at['z_leaf_a.lua'] < at['m_mid.lua'], 'leaves before what requires them')
    ok(at['m_mid.lua'] < at['a_ring1.lua'], 'and before the component above')
    local ring = { at['a_ring1.lua'], at['a_ring2.lua'], at['a_ring3.lua'] }
    table.sort(ring)
    eq(ring[1] + 2, ring[3], 'a cycle renders as one contiguous run')
    symbols.files_mode = 'flat'
end)

test('layers: a cycle ANNOUNCES itself, and the announcement fits the budget',
    function ()
    layered()
    symbols.files_mode = 'layers'
    local lines = render('files')
    local said
    for _, l in ipairs(lines) do if l:find('cycle', 1, true) then said = l end end
    ok(said, 'the mutually-recursive component is named, not drawn as depth')
    ok(said:find('3', 1, true), 'and says how many files: ' .. tostring(said))
    -- the row that was written to FIX clipping must not itself clip: the first
    -- cut of it read "── cycle: N files, mutually recursive ──" at 41 columns
    ok(vim.fn.strdisplaywidth(said) <= 30,
        ('the cycle row is chrome and obeys the budget: %d cols'):format(
            vim.fn.strdisplaywidth(said)))
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

-- ── free TEXT rows: the detail lens ─────────────────────────────────────────
-- Found by a :CartographFeedback entry, which froze the rows it was filed on and
-- so made them measurable after the fact: the detail lens emitted rows up to 82
-- columns — 7 of 15 on one function — into a 30-column pane. The budget work had
-- reached identity rows and never these, and the ratchet below only ever measured
-- the `files` and `ws` altitudes, so nothing was watching.

test('width: free TEXT elides at the TAIL, where an identity elides the middle',
    function ()
    -- a statement reads left to right: the front says which local is being
    -- assigned, so keeping the front is what keeps the row meaningful
    local got = symbols.fit_text('local vonnCharacter = player.surface.create_entity{x=1}', '  ')
    eq(28, vim.fn.strdisplaywidth(got))     -- 30 minus the 2-column indent
    eq('local vonnCharacter = playe…', got) -- head kept, loss MARKED
    -- and an identity of the same length elides the MIDDLE instead
    local id = symbols.fit_identity('crash-site-assembling-machine.lua', '', '')
    assert(id:match('^crash'), id)
    assert(id:match('lua$'), id)  -- both ends carry signal for a name
    assert(id:find('…', 1, true), 'the elision must be marked')
end)

test('width: text that already fits is passed through byte-identical', function ()
    eq('local x = 1', symbols.fit_text('local x = 1', '  '))
end)

test('width: the budget, not a hardcoded bound, decides the fit', function ()
    local saved = config.symbols_width
    config.symbols_width = 50
    eq(48, vim.fn.strdisplaywidth(symbols.fit_text(('x'):rep(200), '  ')))
    config.symbols_width = saved
end)

test('width: the detail provider MARKS its own bound, so a wide budget cannot lie',
    function ()
    -- the pane fitting to 30 hid an unmarked 80-byte cut one layer down; raise the
    -- budget past the provider's bound and the elision must still announce itself
    local ts = require 'cartograph.providers.treesitter'
    local f = vim.fn.tempname() .. '.lua'
    -- the statement must live inside a FORM whose children are statements: detail
    -- reads child forms, so a bare top-level declaration yields nothing
    vim.fn.writefile({ 'local function g()',
        '  local t = { ' .. ('"aaaaaaaa", '):rep(20) .. '}', 'end' }, f)
    local stmts = ts.detail(f, 0, 0, 2, 3)
    assert(#stmts > 0, 'no statements parsed')
    local long = stmts[1].text
    assert(vim.fn.strchars(long) <= 80, 'the bound is gone: ' .. #long)
    assert(long:find('…', 1, true), 'the provider cut without marking: ' .. long)
    vim.fn.delete(f)
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

-- ── LISTS: packed, with the remainder COUNTED ─────────────────────────────────
-- MEASURED on a real function (k-lib.lua::script.register_object, reported via
-- :CartographFeedback): the plain `fn` altitude — the most-seen view in the pane —
-- put 4 of its 7 rows past the budget, the widest at 81 columns in a 30-column
-- window. `inputs:` and the per-statement reads are LISTS, and a list must not be
-- elided like an identity: a truncated list reads as complete. So it packs what fits
-- and counts what it withheld, the same way the mode strip degrades.

test('append_list: packs what fits and counts the rest', function ()
    config.symbols_width = 30
    local got = symbols.append_list('inputs:', ' ',
        { 'events', 'k_lib_events', 'on_init', 'k_lib_on_init', 'on_nth_tick' })
    ok(vim.fn.strdisplaywidth(got) <= 30, ('%d cols: %s'):format(
        vim.fn.strdisplaywidth(got), got))
    ok(got:find('+%d'), 'the withheld names are counted: ' .. got)
    ok(got:find('events', 1, true), 'and what fit is shown: ' .. got)
end)

test('append_list: a list that fits whole gains no count', function ()
    config.symbols_width = 30
    local got = symbols.append_list('inputs:', ' ', { 'a', 'b' })
    eq('inputs: a, b', got)
end)

test('append_list: an empty list adds nothing at all', function ()
    eq('inputs:', symbols.append_list('inputs:', ' ', {}))
end)

test('append_list: the LEAD survives even when no item fits, so the count says'
    .. ' what it counts', function ()
    config.symbols_width = 14
    local got = symbols.append_list('  x', '  ← ',
        { 'a_very_long_identifier', 'another_one' })
    ok(got:find('←', 1, true), 'the relation is still named: ' .. got)
    ok(got:find('+2', 1, true), 'and both are counted: ' .. got)
    config.symbols_width = 30
end)

test('append_list: the count is honest about the exact remainder', function ()
    config.symbols_width = 20
    local got = symbols.append_list('·', ' ', { 'alpha', 'beta', 'gamma', 'delta' })
    local n = tonumber(got:match('%+(%d+)'))
    local shown = 0
    for _, name in ipairs({ 'alpha', 'beta', 'gamma', 'delta' }) do
        if got:find(name, 1, true) then shown = shown + 1 end
    end
    eq(4, shown + (n or 0), 'shown + counted must equal the whole list: ' .. got)
    config.symbols_width = 30
end)

test('fn view: a real function with many inputs fits every row', function ()
    config.symbols_width = 30
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat({
        'local alpha, beta, gamma, delta, epsilon = 1, 2, 3, 4, 5',
        'local function register_object(object)',
        '\tobject.one = alpha',
        '\tobject.two = beta',
        '\tobject.three = gamma',
        '\tobject.four = delta',
        '\tobject.five = epsilon',
        '\treturn object',
        'end',
        'return register_object',
    }, '\n'))
    fd:close()
    local data = require('cartograph.providers.treesitter').extract(root, {})
    store.ingest(data)
    local id
    for _, n in ipairs(data.nodes) do
        if n.name == 'register_object' then id = n.id end
    end
    ok(id, 'the fixture fn was extracted')
    symbols.buf = nil
    symbols.create()
    symbols.view = { level = 'fn', fn = id }
    symbols.render()
    local over = {}
    for i, l in ipairs(vim.api.nvim_buf_get_lines(symbols.buf, 0, -1, false)) do
        local w = vim.fn.strdisplaywidth(l)
        if w > 30 then over[#over + 1] = ('row %d = %d cols: %s'):format(i, w, l) end
    end
    eq({}, over, 'the default altitude must not clip')
end)
