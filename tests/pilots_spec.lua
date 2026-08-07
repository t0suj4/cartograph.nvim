-- THE TWO CONVERSION PILOTS ([[cartograph-interactive-reports]]): a per-fn report
-- as a LENS, and a whole-graph report as a descendable COMPARTMENT. They exist to
-- fix the row contract on two shapes before it gets copied across 45 more report
-- sites, so this spec asserts the CONTRACT, not the prettiness:
--
--   * the rows come from the same records the report formats (one reading, two
--     consumers) — never a second, drifting derivation;
--   * every row's identity fits the budget (a clipped row lies);
--   * a row carries an ANCHOR (file + line, or a node) so the cockpit's own verbs
--     — hover, descend, ascend — work without per-report code;
--   * an empty says WHICH kind of empty it is, both halves;
--   * the address survives: descend, ascend, and a DEAD key each land somewhere
--     honest.

local store    = require 'cartograph.store'
local symbols  = require 'cartograph.panes.symbols'
local concerns = require 'cartograph.panes.concerns'
local proto    = require 'cartograph.prototypes'

local TMP = vim.fn.tempname()

local function render(level, key)
    symbols.buf = nil
    symbols.create()
    symbols.show(level, key)
    return vim.api.nvim_buf_get_lines(symbols.buf, 0, -1, false)
end
--- show(level, key) clears the lens by design ("a fresh navigation starts at the
--- altitude's default lens"), so a lens is chosen AFTER arriving — which is what
--- <Tab> does. Any spec that sets view.lens before show() is testing nothing.
local function render_lens(level, key, lens)
    symbols.buf = nil
    symbols.create()
    symbols.show(level, key)
    symbols.view.lens = lens
    symbols.render()
    local lines = vim.api.nvim_buf_get_lines(symbols.buf, 0, -1, false)
    symbols.view.lens = nil
    return lines
end
local function widest(lines)
    local w = 0
    for _, l in ipairs(lines) do
        local lw = vim.fn.strdisplaywidth(l)
        if lw > w then w = lw end
    end
    return w
end
local function find(lines, pat)
    for i, l in ipairs(lines) do if l:find(pat) then return l, i end end
end

--- A real on-disk fixture: both pilots re-parse (exprlint via expr.of, the
--- prototype reading via expr.of_module), so a synthetic node table is not enough.
local function project(files, profile)
    vim.fn.mkdir(TMP, 'p')
    local nodes = {}
    for name, src in pairs(files) do
        local path = TMP .. '/' .. name
        vim.fn.writefile(vim.split(src, '\n'), path)
        local nl = #vim.split(src, '\n')
        nodes[#nodes + 1] = { id = name, name = name, kind = 'module', file = name,
            range = { start = { line = 0, char = 0 }, ['end'] = { line = nl, char = 0 } },
            order = 0 }
    end
    store._content_cache = {}
    store.ingest({ schema = 1, root = TMP, profile = profile, nodes = nodes, edges = {} })
end

-- ── PILOT 1: a per-fn report as a LENS ──────────────────────────────────────

local LINTY = [[
local function f(a, t)
    if a == a then return 1 end
    local x = t
    x = x
    return x
end
]]

local function linty_fn()
    project({ ['m.lua'] = LINTY })
    -- the fn node the lens hangs on (the fixture's only function)
    store.ingest({ schema = 1, root = TMP, nodes = {
        { id = 'm.lua', name = 'm.lua', kind = 'module', file = 'm.lua',
          range = { start = { line = 0, char = 0 }, ['end'] = { line = 6, char = 0 } },
          order = 0 },
        { id = 'f', name = 'f', kind = 'function', file = 'm.lua',
          range = { start = { line = 0, char = 0 }, ['end'] = { line = 5, char = 3 } },
          order = 0 },
    }, edges = {} })
    return 'f'
end

test('lens: `lints` joins the fn lens set and renders its own rows', function ()
    local id = linty_fn()
    local plain = render('fn', id)
    ok(find(plain, 'ƒ'), 'the default lens is untouched: ' .. table.concat(plain, ' | '))
    local lines = render_lens('fn', id, 'lints')
    ok(find(lines, '⚑'), 'the lints lens renders its own header: '
        .. table.concat(lines, ' | '))
end)

test('lens: rows are the FINDINGS of exprlint.lint — one reading, two consumers',
    function ()
    local id = linty_fn()
    local res = require('cartograph.exprlint').lint(store, id)
    ok(#res.findings > 0, 'the fixture trips rung-0 lints (self-compare, self-assign)')
    local lines = render_lens('fn', id, 'lints')
    for _, f in ipairs(res.findings) do
        ok(find(lines, (f.rule:gsub('%-', '%%-'))),
            ('finding %s has a row'):format(f.rule))
    end
end)

test('lens: every row fits the budget, and the LINE is an annotation not text',
    function ()
    local id = linty_fn()
    local lines = render_lens('fn', id, 'lints')
    ok(widest(lines) <= 30, 'widest lint row = ' .. widest(lines))
    -- the line number rides the vnum lane, so no row TEXT carries digits: an
    -- annotation must not compete with identity for columns (the budget law)
    for i, l in ipairs(lines) do
        if i > 1 then ok(not l:find('%d'), 'row has no line number in its text: ' .. l) end
    end
end)

test('lens: each row ANCHORS to its statement line, so hover needs no new code',
    function ()
    local id = linty_fn()
    render_lens('fn', id, 'lints')
    local anchored = 0
    for _, l in pairs(symbols.line_stmt) do if l then anchored = anchored + 1 end end
    ok(anchored > 0, 'lint rows carry line_stmt (the fn hover highlights it)')
end)

test('lens: never the word CLEAN — a row states what was CHECKED', function ()
    -- ★ THE ORIGINAL PREMISE WAS FIXED, NOT WEAKENED (CART-0314). This test was
    -- written because `def f(a): if a == a:` harvested five expression nodes and
    -- tripped ZERO rung-0 rules — the rules were Lua-authored, so the lens said
    -- "(clean — no rung-0 findings)" about a language nothing had checked. Python's
    -- `comparison_operator` is now in expr's BIN table, so the SAME case reports
    -- `self-compare` with census.unknown = 0: the coverage the test was documenting
    -- the absence of now exists.
    -- The INVARIANT it guards outlives that and is what is asserted below: the lens
    -- never says "clean", and it states either what it read or what it found. Parser
    -- availability is still an ENVIRONMENT fact, so both branches must hold.
    project({ ['a.py'] = 'def f(a):\n    if a == a:\n        return 1\n    return a\n' })
    store.ingest({ schema = 1, root = TMP, nodes = {
        { id = 'a.py', name = 'a.py', kind = 'module', file = 'a.py',
          range = { start = { line = 0, char = 0 }, ['end'] = { line = 4, char = 0 } },
          order = 0 },
        { id = 'pf', name = 'f', kind = 'function', file = 'a.py',
          range = { start = { line = 0, char = 0 }, ['end'] = { line = 3, char = 12 } },
          order = 0 },
    }, edges = {} })
    local lines = render_lens('fn', 'pf', 'lints')
    local joined = table.concat(lines, ' ')
    ok(not joined:find('clean'), 'no all-clear verdict: ' .. joined)
    -- a listed FINDING is also not an all-clear — accept it alongside the
    -- coverage line, since which one appears depends on the parser being present
    ok(joined:find('read') or joined:find('⚠') or joined:find('self%-compare'),
        'it says what was read, or what it found: ' .. joined)
end)

test('lens: a partly-unread function marks its findings a LOWER BOUND', function ()
    local id = linty_fn()
    local res = require('cartograph.exprlint').lint(store, id)
    local lines = render_lens('fn', id, 'lints')
    if res.census.unknown > 0 then
        ok(table.concat(lines, ' '):find('read'),
            'the coverage caveat rides the list: ' .. table.concat(lines, ' | '))
    else
        ok(#res.findings > 0, 'fully-read fixture needs no caveat')
    end
end)

-- ── PILOT 2: a whole-graph report as a COMPARTMENT ──────────────────────────

local MOD = [[
local chest = table.deepcopy(data.raw["container"]["wooden-chest"])
chest.name = "vn-chest"
chest.inventory_size = 8000
chest.next_upgrade = nil
chest.icon = make_icon("x")
mutate(chest)
data:extend{chest}
]]

local function fac() project({ ['data.lua'] = MOD }, 'lua-factorio') end

test('compartment: the roster renders every prototype, fitted, with a count',
    function ()
    fac()
    local lines = render('protos')
    ok(find(lines, 'prototypes'), 'a header names the concern')
    ok(find(lines, 'vn%-chest'), 'the prototype has a row: '
        .. table.concat(lines, ' | '))
    ok(widest(lines) <= 30, 'widest roster row = ' .. widest(lines))
end)

test('compartment: a hedged prototype is marked, not silently equal to a clean one',
    function ()
    fac()
    local lines = render('protos')
    local row = find(lines, 'vn%-chest')
    ok(row:find('~'), 'the ~ hedge rides the row: ' .. row)
end)

test('compartment: rows carry an ANCHOR (file + line) and a KEY to descend',
    function ()
    fac()
    render('protos')
    local key, anchored
    for r, k in pairs(symbols.line_proto) do
        key = k
        anchored = symbols.line_file[r] and symbols.line_stmt[r]
    end
    ok(key, 'a roster row carries a prototype key')
    ok(anchored, 'and a file+line anchor, which is what hover previews')
    -- the key resolves back to the record: invertible by construction
    local rec, file = proto.at(store, key)
    ok(rec and file, 'the key names a record: ' .. tostring(key))
    eq('vn-chest', rec.name)
end)

test('compartment: descending shows the ORDERED overrides and the hedge in place',
    function ()
    fac()
    render('protos')
    local key
    for _, k in pairs(symbols.line_proto) do key = k end
    local lines = render('proto', key)
    local seen = {}
    for _, l in ipairs(lines) do
        if l:find('inventory_size') then seen[#seen + 1] = 'size' end
        if l:find('next_upgrade') then seen[#seen + 1] = 'del' end
        if l:find('icon') then seen[#seen + 1] = 'icon' end
        if l:find('mutate') then seen[#seen + 1] = '~' end
    end
    eq({ 'size', 'del', 'icon', '~' }, seen)  -- source order, hedge where it fired
    ok(widest(lines) <= 30, 'widest override row = ' .. widest(lines))
end)

test('compartment: the markers carry what the VALUE cannot at 30 columns',
    function ()
    fac()
    render('protos')
    local key
    for _, k in pairs(symbols.line_proto) do key = k end
    local lines = render('proto', key)
    ok(find(lines, 'next_upgrade%s*∅'), 'an explicit nil is a DELETE: '
        .. tostring(find(lines, 'next_upgrade')))
    ok(find(lines, 'icon%s*%?'), 'an unread value is marked ?: '
        .. tostring(find(lines, 'icon')))
    -- the value itself is NOT in the row: it is in the source (hover) and in the
    -- report. That is the budget law choosing what a row is for.
    ok(not find(lines, '8000'), 'no values in the rows')
end)

test('compartment: `proto` declares its inverse, so h returns to the roster',
    function ()
    local e = concerns.of('proto')
    ok(e, 'proto is a registry entry')
    eq('proto', e.view_key)
    local level, key = e.ascend('data.lua\0311')
    eq('protos', level)
    eq(nil, key)
    -- and its subject is the DECLARING MODULE (a real node: module ids are paths)
    eq('data.lua', concerns.subject_of('proto', 'data.lua\0311'))
end)

test('compartment: a DEAD key says so instead of rendering an empty prototype',
    function ()
    fac()
    local lines = render('proto', 'data.lua\03199')
    ok(find(lines, 'gone'), 'the row says the address is dead: '
        .. table.concat(lines, ' | '))
    ok(widest(lines) <= 30, 'and it wraps rather than clipping: ' .. widest(lines))
end)

test('compartment: no data stage is UNAVAILABLE, not an empty roster', function ()
    project({ ['plain.lua'] = 'local x = 1\n' })  -- no profile
    local lines = render('protos')
    ok(find(lines, 'unavailable'), 'the header states the kind of empty: '
        .. table.concat(lines, ' | '))
    ok(find(lines, 'data stage'), 'and the reason names what is missing')
    ok(widest(lines) <= 30, 'wrapped, not clipped: ' .. widest(lines))
    eq(nil, proto.all(store))
end)

test('compartment: an APPLICABLE but empty data stage reads differently', function ()
    -- the other half: the adapter applies, there is simply nothing declared
    project({ ['empty.lua'] = 'local x = 1\n' }, 'lua-factorio')
    local lines = render('protos')
    -- the note WRAPS to the budget, so the sentence spans rows — join to assert
    -- it (and note the cost: a wrapped note is not greppable by eye either)
    local joined = table.concat(lines, ' '):gsub('%s+', ' ')
    ok(joined:find('declares no prototypes'),
        'computed-empty says what the absence MEANS: ' .. joined)
    ok(not find(lines, 'unavailable'), 'and does not claim unavailability')
end)
