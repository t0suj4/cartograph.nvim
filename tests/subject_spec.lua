-- THE SUBJECT OF AN ALTITUDE. Recorded law ([[refactor-cockpit-design]], the FSM
-- anchor): "every altitude must hang somewhere in the structural tree or h/l
-- breaks symmetry — a synthetic altitude needs a source-code anchor node, or
-- it's a one-way door." The RELATION altitudes (callers / occs / regfor) never
-- got it: their rows are other nodes referring to a subject that is never itself
-- a row. So mark and cone, keyed on line_node alone, refused everywhere while
-- you traversed references — and at the fn altitude, whose header names a
-- function it never anchored.
--
-- M.subject() answers "what is this view about", M.row_subject(row) answers it
-- per row with a documented fallback, and the four verbs that each open-coded
-- their own probe (mark, cone, gf, the working-set ●) now share them.

local store   = require 'cartograph.store'
local symbols = require 'cartograph.panes.symbols'

local function R(l1, l2)
    return { start = { line = l1, char = 0 }, ['end'] = { line = l2 or l1, char = 0 } }
end
local function fn(id, name, file, l1, l2)
    return { id = id, name = name, kind = 'function', file = file or 'm.lua',
        range = R(l1 or 0, l2), order = l1 or 0 }
end

--- A pane with no window and no buffer: row_subject takes its row explicitly,
--- so every lookup here is exercised headless.
local function reset(nodes, view)
    store.ingest({ schema = 1, root = '/x', nodes = nodes, edges = {} })
    store.workset = { ids = {}, refs = {}, pending = {}, last = nil }
    symbols.win, symbols.buf = nil, nil
    symbols.line_node, symbols.line_about, symbols.line_kind = {}, {}, {}
    symbols.line_site, symbols.line_group, symbols.line_file = {}, {}, {}
    symbols.view = view or { level = 'files' }
end

-- ── M.subject: what the altitude is about ───────────────────────────────────

test('subject: the fn altitude is about the function you descended into', function ()
    reset({ fn('m.lua::f', 'f') }, { level = 'fn', fn = 'm.lua::f' })
    eq('m.lua::f', symbols.subject())
    eq('m.lua::f', symbols.subject('def')) -- and it IS a def altitude
end)

test('subject: a RELATION altitude has a subject that is not any of its rows',
    function ()
    reset({ fn('m.lua::f', 'f') }, { level = 'callers', callers = 'm.lua::f' })
    eq('m.lua::f', symbols.subject())
    -- but NOT for the source pane: widening the def flavour would make an
    -- ascent onto a callers list swap the def pane out from under you
    eq(nil, symbols.subject('def'))
end)

test('subject: the occs altitude is about the USING function, not the entity',
    function ()
    reset({ fn('m.lua::user', 'user'), fn('m.lua::ent', 'ent') },
        { level = 'occs', occs = 'ref\31m.lua::ent\31m.lua::user' })
    eq('m.lua::user', symbols.subject())
end)

test('subject: a malformed occs key yields nil, never an empty-string id',
    function ()
    -- '' is truthy in lua: a naive match would return it and every caller
    -- would then ask store.node('')
    reset({ fn('m.lua::f', 'f') }, { level = 'occs', occs = nil })
    eq(nil, symbols.subject())
end)

test('subject: the files altitude is about nothing — a file is not a node',
    function ()
    reset({ fn('m.lua::f', 'f') }, { level = 'files' })
    eq(nil, symbols.subject())
end)

-- ── M.row_subject: what the ROW is about ────────────────────────────────────

test('row_subject: a symbol row is about its own symbol', function ()
    reset({ fn('m.lua::f', 'f'), fn('m.lua::g', 'g', 'm.lua', 5) },
        { level = 'file', file = 'm.lua' })
    symbols.line_node = { [2] = 'm.lua::f', [3] = 'm.lua::g' }
    local id, from = symbols.row_subject(3)
    eq('m.lua::g', id)
    eq('row', from)
end)

test('row_subject: a REFERENCE row is about the function that contains it',
    function ()
    -- traversing references: the rows are call sites, the thing you want to
    -- mark is the function you landed in
    reset({ fn('m.lua::ent', 'ent'), fn('u.lua::user', 'user', 'u.lua') },
        { level = 'callers', callers = 'm.lua::ent' })
    symbols.line_about = { [2] = 'u.lua::user' }
    local id, from = symbols.row_subject(2)
    eq('u.lua::user', id)
    eq('row', from)
end)

test('row_subject: falls back to the altitude when the row is about nothing',
    function ()
    -- the fn altitude's statement/ladder rows: no row carries a node, which is
    -- why mark used to refuse everywhere once you descended into a function
    reset({ fn('m.lua::f', 'f') }, { level = 'fn', fn = 'm.lua::f' })
    local id, from = symbols.row_subject(7)
    eq('m.lua::f', id)
    eq('altitude', from) -- the caller must say so: there is no row to sign
end)

test('row_subject: an anchor that is not a node falls THROUGH to the altitude',
    function ()
    -- render_regfor builds { fn = <module> }, so site.fn is not always a node.
    -- The chain must skip it rather than name something that is not there —
    -- and must not stop at the nil, either: written as an `or` chain because
    -- ipairs over the alternatives stops at the first nil (the bug that cost
    -- resolve_module_alias 845 fills).
    reset({ fn('m.lua::f', 'f') }, { level = 'regfor', regfor = 'm.lua::f' })
    symbols.line_site = { [2] = { fn = 'some/module.lua' } } -- not a node
    local id, from = symbols.row_subject(2)
    eq('m.lua::f', id)
    eq('altitude', from)
end)

test('row_subject: a live LATER alternative survives an earlier nil', function ()
    -- line_node absent, line_about present: the second alternative must be
    -- reached (the ipairs trap, pinned directly)
    reset({ fn('m.lua::f', 'f'), fn('m.lua::g', 'g', 'm.lua', 5) },
        { level = 'file', file = 'm.lua' })
    symbols.line_node = {}
    symbols.line_about = { [4] = 'm.lua::g' }
    eq('m.lua::g', (symbols.row_subject(4)))
end)

test('row_subject: nothing anywhere is nil, not a guess', function ()
    reset({ fn('m.lua::f', 'f') }, { level = 'files' })
    eq(nil, symbols.row_subject(3))
end)

-- ── hover: the altitudes whose ROWS ARE NODES ───────────────────────────────
-- The CursorMoved handler is a closure inside attach() and unreachable from a
-- spec. Its BODY is M.hover_node and its DECISION is M.NODE_HOVER membership —
-- and the bug was entirely in the decision, so a spec that only called
-- hover_node would pass against it. Both halves are asserted.

test('hover: the working set is IN the node-hover class', function ()
    -- THE BUG: ws was never added to the hover dispatch, so navigating the
    -- working set — the altitude whose whole job is re-orientation after a code
    -- dive — left the source pane on whatever it happened to be showing.
    -- hover_node was fine; nothing ever called it here.
    ok(symbols.NODE_HOVER.ws, 'the working set previews its members')
    ok(symbols.NODE_HOVER.refused, 'so does the candidate list (same omission)')
    ok(not symbols.NODE_HOVER.fn, 'the fn altitude highlights statements instead')
    ok(not symbols.NODE_HOVER.files, 'a file row is not a node row')
end)

test('hover: a working-set row previews its member in the source pane', function ()
    reset({ fn('m.lua::f', 'f'), fn('m.lua::g', 'g', 'm.lua', 5) },
        { level = 'ws' })
    store.set_focus('m.lua::f')
    store.set_context(nil)
    symbols.line_node = { [3] = 'm.lua::g' }
    eq('m.lua::g', symbols.hover_node(3))
    eq('m.lua::g', store.context and store.context.node)
end)

test('hover: hovering the row you are already focused on drops the takeover',
    function ()
    reset({ fn('m.lua::f', 'f') }, { level = 'ws' })
    store.set_focus('m.lua::f')
    store.set_context({ node = 'm.lua::f' })
    symbols.line_node = { [2] = 'm.lua::f' }
    eq('m.lua::f', symbols.hover_node(2))
    eq(nil, store.context) -- nothing to preview: the def pane already shows it
end)

test('hover: a non-node row previews nothing and says so', function ()
    reset({ fn('m.lua::f', 'f') }, { level = 'ws' })
    store.set_context(nil)
    symbols.line_node = {}
    eq(nil, symbols.hover_node(1)) -- a header/chrome row: the caller may fall through
    eq(nil, store.context)
end)

-- ── the working-set ● overlay: paint on what a row IS ───────────────────────

test('ws ●: only FILE rows carry the file-level dot, not every row in the file',
    function ()
    -- THE BUG: line_file is set on member rows too (hover/gf/staging need it),
    -- so keying the file-level ● on it dotted every row of any file that held a
    -- mark — one mark, a column of dots.
    reset({ fn('m.lua::f', 'f'), fn('m.lua::g', 'g', 'm.lua', 5) },
        { level = 'file', file = 'm.lua' })
    local buf = vim.api.nvim_create_buf(false, true)
    symbols.buf = buf
    store.ws_toggle('m.lua::f')
    symbols.render()

    local dots = {}
    for _, e in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
        if e[4] and e[4].sign_text and e[4].sign_text:find('●') then
            dots[e[2] + 1] = true
        end
    end
    local rows = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local frow, grow
    for i, l in ipairs(rows) do
        if l:find('ƒ f$') then frow = i elseif l:find('ƒ g$') then grow = i end
    end
    ok(frow and grow, 'both members rendered: ' .. vim.inspect(rows))
    ok(dots[1], 'the file header keeps its dot (this file does hold a member)')
    ok(dots[frow], 'the MARKED member is dotted')
    ok(not dots[grow], 'the unmarked member is NOT — it only shares the file')
    vim.api.nvim_buf_delete(buf, { force = true })
    symbols.buf = nil
end)
