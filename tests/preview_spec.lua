-- ALTERNATE VIEWS of the source pane's subject.
--
-- The pane had rendered exactly one thing about its subject since it existed:
-- the source. Which left the files altitude unserved — a whole file is not a
-- recognition anchor — while the fact a file row actually carries, its PLACE in
-- the import graph, was too wide for the 30-column browser and so was shown
-- nowhere. Reported from the browser as the include tree being unreadable; the
-- measurement said a one-level neighbourhood is 6 rows at the median, 36 at p90,
-- which fits the main pane whole.
--
-- These pin the seam (`view = { name = … }` on the context channel) and the two
-- hazards that come with generated lines living in a source pane.

local store  = require 'cartograph.store'
local source = require 'cartograph.panes.source'

local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
local R4 = { start = { line = 0, char = 0 }, ['end'] = { line = 4, char = 0 } }
local function mod(name, extra)
    local n = { id = name, name = name, kind = 'module', file = name,
        range = R4, order = 0 }
    for k, v in pairs(extra or {}) do n[k] = v end
    return n
end
local function fn(id, file)
    return { id = id, name = id, kind = 'function', file = file, range = R0, order = 1 }
end
local function imp(a, b) return { kind = 'import', from = a, to = b } end

--- `mid.lua` requires two leaves and is required by one caller; `sleepy.lua` is
--- lazy and `blob.bin` unparsed — the two whose neighbourhood is UNKNOWN.
--- REAL FILES on disk: `body_lines` reads source, so a fixture of bare nodes
--- makes the pane too short for an extmark to land and the highlight test below
--- passes for the wrong reason (it did, before this).
local root
local function graph()
    root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for _, f in ipairs({ 'mid.lua', 'leaf_a.lua', 'leaf_b.lua', 'top.lua',
        'sleepy.lua', 'blob.bin' }) do
        local fd = assert(io.open(root .. '/' .. f, 'w'))
        fd:write('-- ' .. f .. '\nlocal a = 1\nlocal b = 2\nlocal c = 3\nreturn a\n')
        fd:close()
    end
    store.ingest({ schema = 1, root = root, nodes = {
        mod('mid.lua'), mod('leaf_a.lua'), mod('leaf_b.lua'), mod('top.lua'),
        mod('sleepy.lua', { lazy = true }), mod('blob.bin', { unparsed = true }),
        fn('f1', 'leaf_a.lua'), fn('f2', 'leaf_a.lua'), fn('f3', 'leaf_b.lua'),
    }, edges = {
        imp('mid.lua', 'leaf_a.lua'), imp('mid.lua', 'leaf_b.lua'),
        imp('top.lua', 'mid.lua'),
    } })
    source.buf = nil
    source.create()
end
local function lines()
    return vim.api.nvim_buf_get_lines(source.buf, 0, -1, false)
end
local function joined() return table.concat(lines(), '\n') end

test('preview: a file row previews BOTH directions of its one hop', function ()
    graph()
    source.context({ node = 'mid.lua', view = { name = 'nbhd' } })
    local t = joined()
    ok(t:find('requires (2)', 1, true), t)
    ok(t:find('required by (1)', 1, true), t)
    ok(t:find('leaf_a.lua', 1, true) and t:find('leaf_b.lua', 1, true), t)
    ok(t:find('top.lua', 1, true), 'the INBOUND direction is here too, not just out')
    -- the def count is what makes a neighbour worth going to
    ok(t:find('2 defs', 1, true), 'leaf_a carries its two defs: ' .. t)
    ok(t:find('1 def\n', 1, true) or t:find('1 def ', 1, true), 'and singular reads singular')
end)

test('preview: every neighbour row is a DOOR — it maps to the file it names',
    function ()
    graph()
    source.context({ node = 'mid.lua', view = { name = 'nbhd' } })
    local rows, ls = source._view_rows, lines()
    local n = 0
    for r, f in pairs(rows) do
        n = n + 1
        ok(ls[r]:find(f, 1, true), ('row %d maps to %s but reads %q'):format(r, f, ls[r]))
    end
    eq(3, n) -- two out, one in; the headers and blanks map to nothing
end)

-- THE HONESTY PIN, and the reason this view could not just count a list: a lazy
-- module has not been read, so `requires (0)` would be a fabricated fact — the
-- invented absence the browser refuses everywhere else.
test('preview: a module that was never read says UNKNOWN, never a rendered zero',
    function ()
    graph()
    for _, id in ipairs({ 'sleepy.lua', 'blob.bin' }) do
        source.context({ node = id, view = { name = 'nbhd' } })
        local t = joined()
        ok(t:find('unknown', 1, true), id .. ' must say so: ' .. t)
        ok(not t:find('requires (0)', 1, true),
            id .. ' must NOT claim it requires nothing: ' .. t)
    end
end)

test('preview: clearing the context restores the body, never strands the pane',
    function ()
    graph()
    source.render('leaf_a.lua')
    local before = joined()
    source.context({ node = 'mid.lua', view = { name = 'nbhd' } })
    ok(joined():find('required by', 1, true), 'the preview took the pane')
    source.context(nil)
    eq(before, joined())
    eq(nil, source._view)
end)

-- source ranges do not address generated lines, so painting one would highlight
-- an arbitrary row of the preview
test('preview: a source highlight is a NO-OP while a generated view shows',
    function ()
    graph()
    local ns = vim.api.nvim_get_namespaces()['cartograph_source_hl']
    -- CONTROL first: on the ordinary source rendering the same call DOES paint,
    -- so an empty result below means the guard fired, not that nothing ever does
    source.context({ node = 'mid.lua' })
    source.highlight({ file = 'mid.lua', ranges = { R0 } })
    ok(#vim.api.nvim_buf_get_extmarks(source.buf, ns, 0, -1, {}) > 0,
        'the control paints — otherwise this test proves nothing')
    source.context({ node = 'mid.lua', view = { name = 'nbhd' } })
    source.highlight({ file = 'mid.lua', ranges = { R0 } })
    eq({}, vim.api.nvim_buf_get_extmarks(source.buf, ns, 0, -1, {}))
    vim.fn.delete(root, 'rf')
end)
