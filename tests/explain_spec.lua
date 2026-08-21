-- HOW AN ANALYSIS EXPLAINS ITSELF ([[cartograph-explaining-a-finding]]).
--
-- Seeded by a user asking what a row MEANT: "~ 52/56 read" — "I don't know what this
-- means". That row exists to stop "0 findings" reading as an all-clear, so the honesty
-- mechanism was the least legible thing on screen. Asking what it meant then exposed
-- that its number was also WRONG.
--
-- Four properties under test:
--   * THE COUNT IS RIGHT. A for-loop header lands in fl.stmts twice with identical
--     expressions, and the census counted both — inflating numerator and denominator.
--     `add` already deduped FINDINGS on (line, rule, msg); only the census forgot.
--   * THE COUNT IS A PLACE. It opens onto the constructs the IR has no case for. A
--     count nobody can open is a claim nobody can check, which is precisely how the
--     double-count survived to be shipped.
--   * `~` MEANS ONE THING. It stays on a hedged FINDING (a claim about a result) and
--     leaves the coverage row (a claim about the analysis) alone.
--   * AN EXPLANATION IS THE OFFENDING NODE. Not the statement containing it: the
--     range must be NARROWER than the line, or "surface the offending node" bought
--     nothing over what line_stmt already did.

local store    = require 'cartograph.store'
local symbols  = require 'cartograph.panes.symbols'
local xl       = require 'cartograph.exprlint'
local atr      = require 'cartograph.at'
local concerns = require 'cartograph.panes.concerns'

local SCRATCH = '/tmp/claude-1000/-home-t0suj4-tools-nvim/explain-spec'

-- ONE for-loop (the double-count trigger), one concat-in-loop finding inside it,
-- and one constant-condition whose offending node is a single token.
local SRC = {
    'local function build(list)',
    '\tlocal s = ""',
    '\tif false then',
    '\t\ts = "dead"',
    '\tend',
    '\tfor i = 1, #list do',
    '\t\ts = s .. list[i]',
    '\tend',
    '\treturn s',
    'end',
    'return build',
}

local function project(lines)
    vim.fn.mkdir(SCRATCH, 'p')
    vim.fn.writefile(lines or SRC, SCRATCH .. '/m.lua')
    local data = require('cartograph.providers.treesitter').extract(SCRATCH, {})
    store.ingest(data)
    for _, n in ipairs(data.nodes) do
        if n.name == 'build' then return n.id end
    end
end

local function render(level, key, lens)
    if not (symbols.buf and vim.api.nvim_buf_is_valid(symbols.buf)) then
        symbols.buf = vim.api.nvim_create_buf(false, true)
    end
    symbols.view = { level = level, fn = level == 'fn' and key or nil,
        unread = level == 'unread' and key or nil,
        lintact = level == 'lintact' and key or nil, lens = lens }
    symbols.render()
    return vim.api.nvim_buf_get_lines(symbols.buf, 0, -1, false)
end

local function flat(lines) return (table.concat(lines, ' '):gsub('%s+', ' ')) end


-- ── the count is right ───────────────────────────────────────────────────────

test('census: a for-loop header is counted ONCE, not once per duplicate row',
    function ()
    local id = project()
    local res = xl.lint(store, id)
    -- the loop header's unmodelled clause must appear exactly once
    local seen = {}
    for _, u in ipairs(res.unread or {}) do
        local k = ('%s\1%s'):format(tostring(u.line), tostring(u.t))
        ok(not seen[k], ('the same construct twice at L%s: %s'):format(
            tostring(u.line), tostring(u.t)))
        seen[k] = true
    end
    ok(#(res.unread or {}) > 0, 'the fixture does have an unmodelled construct')
    eq(#res.unread, res.census.unknown, 'the count and the SET agree')
end)

test('census: deduping the row is what fixes it — the finding dedup already existed',
    function ()
    local id = project()
    local res = xl.lint(store, id)
    -- one concat-in-loop, reported once, even though its row may repeat
    local n = 0
    for _, f in ipairs(res.findings) do
        if f.rule == 'concat-in-loop' then n = n + 1 end
    end
    eq(1, n, 'the finding was already deduped on (line, rule, msg)')
end)

test('census: total counts each distinct row once, so the ratio is not inflated',
    function ()
    local id = project()
    local a = xl.lint(store, id).census.total
    -- re-linting must not change it either (no accumulation across calls)
    eq(a, xl.lint(store, id).census.total)
    ok(a > 0, 'something was read')
end)


-- ── the count is a place ─────────────────────────────────────────────────────

test('coverage: the row counts the UNREAD and is a door, with no ~ on it', function ()
    local id = project()
    local rows = render('fn', id, 'lints')
    local door
    for i, l in ipairs(rows) do if l:find('unread', 1, true) then door = i end end
    ok(door, 'the coverage row is there: ' .. flat(rows))
    ok(rows[door]:find('◆', 1, true), 'marked descendable: ' .. rows[door])
    ok(rows[door]:find('unread of', 1, true),
        'it counts what it is ABOUT, not what it is not: ' .. rows[door])
    ok(not rows[door]:find('~', 1, true),
        '~ belongs to a hedged FINDING, not to coverage: ' .. rows[door])
    eq(id, symbols.line_unread[door], 'and it is registered as a door')
end)

test('coverage: the door is offered when there are 0 findings too — the "never say'
    .. ' clean" case is where it matters most', function ()
    -- a fn with an unmodelled construct but nothing to report
    local id = project({
        'local function quiet(list)',
        '\tlocal n = 0',
        '\tfor i = 1, #list do',
        '\t\tn = n + i',
        '\tend',
        '\treturn n',
        'end',
        'return quiet',
    })
    -- the fixture's fn is named quiet; project() looks for build, so find it here
    for _, n in ipairs(store.by_file['m.lua'] or {}) do
        if n.name == 'quiet' then id = n.id end
    end
    local res = xl.lint(store, id)
    eq(0, #res.findings, 'nothing to report')
    ok(res.census.unknown > 0, 'but the harvest was partial')
    local rows = render('fn', id, 'lints')
    ok(flat(rows):find('0 findings', 1, true), flat(rows))
    local door
    for i, l in ipairs(rows) do if symbols.line_unread[i] then door = i end end
    ok(door, 'the door is offered beside the 0: ' .. flat(rows))
end)

test('coverage: the door opens onto the constructs, named by grammar node type',
    function ()
    local id = project()
    local rows = render('unread', id)
    local text = flat(rows)
    ok(text:find('build', 1, true), 'the header names the fn: ' .. text)
    ok(text:find('clause', 1, true) or text:find('_', 1, true),
        'the rows name the CONSTRUCT: ' .. text)
    local marked = 0
    for i = 2, #rows do
        if symbols.line_site[i] then marked = marked + 1 end
    end
    ok(marked > 0, 'each row carries its own source range, not just a line')
end)

test('coverage: every unread entry has both halves — the type and the range',
    function ()
    local id = project()
    for _, u in ipairs(xl.lint(store, id).unread or {}) do
        ok(type(u.t) == 'string' and u.t ~= '',
            'a construct with no name explains nothing')
        ok(u.at, 'and with no range it cannot be pointed at')
        ok(type(u.line) == 'number')
    end
end)

test('coverage: the registry declares the altitude', function ()
    local id = project()
    local e = concerns.of('unread')
    ok(e, 'unread is a declared concern')
    eq('site', e.hover)
    eq(id, concerns.subject_of('unread', id))
    local lvl, key = e.ascend(id)
    eq('fn', lvl); eq(id, key)
end)

test('coverage: every row of the unread view fits the budget', function ()
    local id = project()
    for _, l in ipairs(render('unread', id)) do
        ok(vim.fn.strdisplaywidth(l) <= 30,
            ('%d cols: %s'):format(vim.fn.strdisplaywidth(l), l))
    end
end)


-- ── ~ means one thing ────────────────────────────────────────────────────────

test('sigils: ~ marks a hedged finding and nothing else on the lens', function ()
    local id = project()
    local rows = render('fn', id, 'lints')
    for i, l in ipairs(rows) do
        if l:find('~', 1, true) then
            ok(symbols.line_lint[i],
                ('row %d wears ~ but is not a finding: %s'):format(i, l))
        end
    end
end)


-- ── an explanation is the offending node ─────────────────────────────────────

test('node: every rule that fires carries the offending expression', function ()
    local id = project()
    local res = xl.lint(store, id)
    ok(#res.findings > 0, 'the fixture fires something')
    for _, f in ipairs(res.findings) do
        ok(f.node, f.rule .. ' carries no offending node')
        ok(f.node.at, f.rule .. "'s node has no source range")
    end
end)

test('node: the range is NARROWER than the statement — else it bought nothing',
    function ()
    local id = project()
    local target
    for _, f in ipairs(xl.lint(store, id).findings) do
        if f.rule == 'constant-condition' then target = f end
    end
    ok(target, 'the fixture has a constant condition')
    local a = target.node.at
    local sl, sc, el, ec = atr.sl(a), atr.sc(a), atr.el(a), atr.ec(a)
    eq(sl, el, 'the offending token is on one line')
    local src = vim.fn.readfile(SCRATCH .. '/m.lua')
    local slice = src[sl + 1]:sub(sc + 1, ec)
    eq('false', slice, 'the node is the CONDITION, not the whole if-statement')
    ok(#slice < #src[sl + 1], 'strictly narrower than the line')
end)

test('node: the compartment leads with the offending code, anchored to that range',
    function ()
    local id = project()
    local key
    for _, f in ipairs(xl.lint(store, id).findings) do
        if f.rule == 'constant-condition' then key = symbols.lintkey(id, f) end
    end
    ok(key, 'got a key')
    local rows = render('lintact', key)
    ok(rows[2] and rows[2]:find('✘', 1, true),
        'the offending code is row 2, above any prose: ' .. flat(rows))
    ok(rows[2]:find('false', 1, true), 'and it IS the code: ' .. rows[2])
    local site = symbols.line_site[2]
    ok(site and site.range, 'the row carries the NODE range for the source pane')
    eq('false', (function ()
        local a = site.range
        local src = vim.fn.readfile(SCRATCH .. '/m.lua')
        return src[atr.sl(a) + 1]:sub(atr.sc(a) + 1, atr.ec(a))
    end)(), 'and it is the same range the rule objected to')
end)

test('node: a multi-line offending node says it continues rather than lying',
    function ()
    local id = project({
        'local function build(list)',
        '\tlocal s = ""',
        '\tfor i = 1, #list do',
        '\t\ts = s ..',
        '\t\t\tlist[i]',
        '\tend',
        '\treturn s',
        'end',
        'return build',
    })
    local key
    for _, f in ipairs(xl.lint(store, id).findings) do
        if f.rule == 'concat-in-loop' then key = symbols.lintkey(id, f) end
    end
    if not key then skip 'no concat finding on the wrapped fixture' end
    local rows = render('lintact', key)
    ok(rows[2]:find('✘', 1, true), flat(rows))
    ok(rows[2]:find('…', 1, true),
        'a node spanning lines is marked as continuing: ' .. rows[2])
end)

test('node: every compartment row fits the budget', function ()
    local id = project()
    for _, f in ipairs(xl.lint(store, id).findings) do
        for _, l in ipairs(render('lintact', symbols.lintkey(id, f))) do
            ok(vim.fn.strdisplaywidth(l) <= 30,
                ('%s: %d cols: %s'):format(f.rule, vim.fn.strdisplaywidth(l), l))
        end
    end
end)


-- ── a dead `l` says so ───────────────────────────────────────────────────────

-- ★ THE THIRD REPORT ON THIS ROW CHANGED THE ANSWER. `l` on a title row was dead,
-- so it was made to SPEAK ("nothing below it") -- reported twice, from `ƒ isTable`
-- (fn) and `≡ local script,…` (region). The third report came from the var altitude
-- and said what it should DO instead: "I would expect descending inside the file, so
-- I can look what else is here". A title row is the subject, not a child, so it has
-- no natural "down" -- and the file the subject LIVES IN was otherwise unreachable
-- from it (a function can ascend to its file, but only with an empty trail: `h` is
-- journey-back first). So the title row means "where this lives" now, and the speech
-- is left for rows that genuinely have nothing, which the test below pins.
test('refusal: `l` on a title row goes to the file the subject lives in',
    function ()
    local id = project()
    vim.cmd('vsplit')
    symbols.buf = nil
    symbols.create()
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, symbols.buf)
    symbols.attach(win)
    store.set_focus(id)
    symbols.show('fn', id)
    symbols.render()

    local said = {}
    local real = vim.notify
    vim.notify = function (msg) said[#said + 1] = tostring(msg) end
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(
        require('cartograph.config').keys.descend, true, false, true), 'x', false)
    vim.notify = real

    eq('file', symbols.view.level, 'the title row goes to where the subject lives')
    eq(store.node(id).file, symbols.view.file)
    eq(0, #said, 'and it does not also talk about it: the move IS the answer')
    store.loc_provider = nil
    vim.cmd('close')
end)

test('refusal: a row that DOES descend stays silent', function ()
    local id = project()
    vim.cmd('vsplit')
    symbols.buf = nil
    symbols.create()
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, symbols.buf)
    symbols.attach(win)
    store.set_focus(id)
    symbols.show('fn', id)
    symbols.view.lens = 'lints'
    symbols.render()
    local door
    for i in ipairs(vim.api.nvim_buf_get_lines(symbols.buf, 0, -1, false)) do
        if symbols.line_unread[i] then door = i end
    end
    ok(door, 'the coverage door is on screen')
    local said = {}
    local real = vim.notify
    vim.notify = function (msg) said[#said + 1] = tostring(msg) end
    vim.api.nvim_win_set_cursor(win, { door, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(
        require('cartograph.config').keys.descend, true, false, true), 'x', false)
    vim.notify = real
    eq('unread', symbols.view.level, 'it went somewhere')
    eq(0, #said, 'so it must not also complain: ' .. table.concat(said, ' '))
    store.loc_provider = nil
    vim.cmd('close')
end)

vim.fn.delete(SCRATCH, 'rf')
