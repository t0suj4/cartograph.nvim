-- THE LINT ACTIONS. A finding row states WHAT is wrong in 30 columns; the WHY and
-- the actions live one descend down (asked for as "descend into a list of suggested
-- actions (supress/solve and so on...)").
--
-- The rules under test are the honesty ones, because they are what makes this
-- different from a menu:
--   * a SUPPRESSED finding is still counted and still reported. A linter that hides
--     what it was told to ignore cannot be audited, and "0 findings" would once
--     again mean two different things.
--   * the marker goes TRAILING, never on a line above: inserting a line shifts
--     every range below it, so the write would invalidate the map it was issued
--     from.
--   * an UNKNOWN comment syntax REFUSES. Guessing `--` into a Ruby file writes a
--     syntax error.
--   * `fix` is always OFFERED and always states its own unavailability. An action
--     list that omits the option it has not implemented says neither "there is no
--     safe rewrite" nor "nobody wrote one yet".

local store    = require 'cartograph.store'
local symbols  = require 'cartograph.panes.symbols'
local xl       = require 'cartograph.exprlint'
local suppress = require 'cartograph.suppress'

local SCRATCH = '/tmp/claude-1000/-home-t0suj4-tools-nvim/lintact-spec'

-- A real file with a real rung-0 finding: `s = s .. x` inside a loop.
local SRC = {
    'local function build(list)',
    '\tlocal s = ""',
    '\tfor _, x in ipairs(list) do',
    '\t\ts = s .. x',
    '\tend',
    '\treturn s',
    'end',
    'return build',
}

local function project(lines)
    vim.fn.mkdir(SCRATCH, 'p')
    vim.fn.writefile(lines or SRC, SCRATCH .. '/m.lua')
    local ts = require 'cartograph.providers.treesitter'
    local data = ts.extract(SCRATCH, {})
    store.ingest(data)
    for _, n in ipairs(data.nodes) do
        if n.name == 'build' then return n.id end
    end
end

local function findings(fn_id) return xl.lint(store, fn_id) end

--- Joined AND whitespace-collapsed: note() word-wraps prose across rows, so a
--- phrase spans two rows with an indent between them. A raw concat would make
--- every prose assertion depend on where the wrap happened to land.
local function flat(lines) return (table.concat(lines, ' '):gsub('%s+', ' ')) end


-- ── the reader ───────────────────────────────────────────────────────────────

test('lint: the finding is there to begin with', function ()
    local id = project()
    ok(id, 'the fn was extracted')
    local res = findings(id)
    eq(1, #res.findings)
    eq('concat-in-loop', res.findings[1].rule)
    eq(0, res.census.suppressed)
end)

test('suppress: a TRAILING marker silences it, and the count discloses that',
    function ()
    local src = vim.deepcopy(SRC)
    src[4] = src[4] .. '  -- @cg-ignore: concat-in-loop'
    local id = project(src)
    local res = findings(id)
    eq(0, #res.findings)          -- silenced
    eq(1, #res.suppressed)        -- but NOT hidden
    eq(1, res.census.suppressed)
    eq('concat-in-loop', res.suppressed[1].rule)
    ok(res.suppressed[1].suppressed_by:find('@cg-ignore', 1, true),
        'the finding carries the marker that silenced it')
end)

test('suppress: a marker on the COMMENT LINE ABOVE works too', function ()
    local src = vim.deepcopy(SRC)
    table.insert(src, 4, '\t\t-- @cg-ignore: concat-in-loop')
    local id = project(src)
    eq(1, #findings(id).suppressed)
end)

test('suppress: a marker naming ANOTHER rule does not silence this one', function ()
    -- one marker must not silence everything the line could ever be flagged for
    local src = vim.deepcopy(SRC)
    src[4] = src[4] .. '  -- @cg-ignore: self-compare'
    local id = project(src)
    eq(1, #findings(id).findings)
    eq(0, #findings(id).suppressed)
end)

test('suppress: a BARE marker silences every rule on the line', function ()
    local src = vim.deepcopy(SRC)
    src[4] = src[4] .. '  -- @cg-ignore'
    local id = project(src)
    eq(1, #findings(id).suppressed)
end)

test('suppress: CODE between the marker and the finding stops the walk', function ()
    -- adhesion: a comment two statements up is not about this line
    local src = vim.deepcopy(SRC)
    table.insert(src, 4, '\t\t-- @cg-ignore: concat-in-loop')
    table.insert(src, 5, '\t\tlocal y = 1')
    local id = project(src)
    eq(1, #findings(id).findings, 'the marker must not reach past code')
end)

test('report: a suppressed finding is LISTED, never merely absent', function ()
    local src = vim.deepcopy(SRC)
    src[4] = src[4] .. '  -- @cg-ignore: concat-in-loop'
    local id = project(src)
    local out = flat(xl.report(store, id))
    ok(out:find('suppressed by the source: 1'), out)
    ok(out:find('concat%-in%-loop'), 'and names the rule it silenced')
end)

-- ── the writer ───────────────────────────────────────────────────────────────

test('suppress: an unknown comment syntax REFUSES rather than guessing', function ()
    local lead, why = suppress.lead_for('thing.rb')
    eq('#', lead) -- known
    lead, why = suppress.lead_for('thing.wat')
    eq(nil, lead)
    ok(why:find('refusing to guess'), why)
    lead, why = suppress.lead_for('Makefile')
    eq(nil, lead)
    ok(why:find('no extension'), why)
end)

test('suppress: the plan APPENDS — it never inserts a line', function ()
    local id = project()
    local f = findings(id).findings[1]
    local plan = assert(suppress.plan(store, 'm.lua', f.line, f.rule))
    eq(f.line, plan.lnum)
    ok(plan.after:find(plan.before, 1, true) == 1,
        'the original line is still the head of the new one')
    ok(plan.after:find('@cg%-ignore: concat%-in%-loop'), plan.after)
    -- the reason it appends: an inserted line would shift every range below it
    eq(#SRC, #vim.fn.readfile(SCRATCH .. '/m.lua'))
end)

test('suppress: apply then read back — the finding is silenced and disclosed',
    function ()
    local id = project()
    local f = findings(id).findings[1]
    local plan = assert(suppress.plan(store, 'm.lua', f.line, f.rule))
    assert(suppress.apply(store, plan))
    -- the file kept its line COUNT, so every range in the graph is still true
    eq(#SRC, #vim.fn.readfile(SCRATCH .. '/m.lua'))
    local res = findings(id)
    eq(0, #res.findings)
    eq(1, #res.suppressed)
    -- and the inverse action puts it back
    local un = assert(suppress.unplan(store, 'm.lua', f.line))
    eq(SRC[4], un.after) -- byte-identical to what we started from
end)

test('suppress: planning twice refuses — no stacked markers', function ()
    local id = project()
    local f = findings(id).findings[1]
    assert(suppress.apply(store, assert(suppress.plan(store, 'm.lua', f.line, f.rule))))
    local plan, why = suppress.plan(store, 'm.lua', f.line, f.rule)
    eq(nil, plan)
    ok(why:find('already carries'), why)
end)

test('suppress: a line that DRIFTED since planning is refused, not clobbered',
    function ()
    local id = project()
    local f = findings(id).findings[1]
    local plan = assert(suppress.plan(store, 'm.lua', f.line, f.rule))
    local src = vim.deepcopy(SRC)
    src[f.line] = '\t\ts = s .. tostring(x)' -- someone edited it
    vim.fn.writefile(src, SCRATCH .. '/m.lua')
    local ok_a, why = suppress.apply(store, plan)
    eq(nil, ok_a)
    ok(why:find('changed since'), why)
end)

-- ── the compartment ──────────────────────────────────────────────────────────

local function render_lintact(key)
    symbols.buf = nil
    symbols.create()
    symbols.show('lintact', key)
    return vim.api.nvim_buf_get_lines(symbols.buf, 0, -1, false)
end

test('lintact: the compartment carries the message the 30-column row could not',
    function ()
    local id = project()
    local f = findings(id).findings[1]
    local lines = render_lintact(symbols.lintkey(id, f))
    local all = flat(lines)
    ok(all:find('concat%-in%-loop'), 'the rule is the identity: ' .. lines[1])
    ok(all:find('O%(n²%)') or all:find('table.concat'), 'the EXPLANATION is here: ' .. all)
    -- and every row fits the pane
    for _, l in ipairs(lines) do
        ok(vim.fn.strdisplaywidth(l) <= 30, 'over budget: ' .. l)
    end
end)

test('lintact: offers suppress, and the FIX row states its unavailability',
    function ()
    local id = project()
    local f = findings(id).findings[1]
    local lines = render_lintact(symbols.lintkey(id, f))
    local all = flat(lines)
    ok(all:find('suppress here'), all)
    -- `fix` is PRESENT and honest, never omitted
    ok(all:find('no mechanical fix'), all)
    ok(all:find('restructures') or all:find('judgement'),
        'with the per-rule reason: ' .. all)
    -- the action row is wired to a verb, not decorative
    local acted
    for r, a in pairs(symbols.line_act) do
        if a.verb == 'suppress' then acted = { r = r, a = a } end
    end
    ok(acted, 'a row carries the suppress action')
    eq(f.line, acted.a.lnum)
    eq('m.lua', acted.a.file)
end)

test('lintact: an ALREADY suppressed finding offers the inverse, not a second one',
    function ()
    local src = vim.deepcopy(SRC)
    src[4] = src[4] .. '  -- @cg-ignore: concat-in-loop'
    local id = project(src)
    local f = findings(id).suppressed[1]
    local lines = render_lintact(symbols.lintkey(id, f))
    local all = flat(lines)
    ok(all:find('un%-suppress'), all)
    ok(not all:find('suppress here'), 'never both: ' .. all)
    ok(all:find('∅ suppressed by'), 'and it says what silenced it: ' .. all)
end)

test('lintact: a key whose finding is GONE says so instead of an empty menu',
    function ()
    local id = project()
    local lines = render_lintact(symbols.lintkey(id, { line = 4, rule = 'no-such-rule' }))
    local all = flat(lines)
    ok(all:find('no longer reported'), all)
end)

test('lintact: the lens row carries the KEY that opens the compartment', function ()
    local id = project()
    symbols.buf = nil
    symbols.create()
    symbols.show('fn', id)
    symbols.view.lens = 'lints'
    symbols.render()
    local keys = {}
    for _, k in pairs(symbols.line_lint) do keys[#keys + 1] = k end
    eq(1, #keys)
    local f = symbols.lintat(keys[1])
    ok(f, 'the key round-trips back to its finding')
    eq('concat-in-loop', f.rule)
end)

test('lints lens: the suppressed count is DISCLOSED on the lens itself', function ()
    local src = vim.deepcopy(SRC)
    src[4] = src[4] .. '  -- @cg-ignore: concat-in-loop'
    local id = project(src)
    symbols.buf = nil
    symbols.create()
    symbols.show('fn', id)
    symbols.view.lens = 'lints'
    symbols.render()
    local all = flat(vim.api.nvim_buf_get_lines(symbols.buf, 0, -1, false))
    -- 0 findings AND something silenced is not the same as 0 findings
    ok(all:find('1 suppressed here'), all)
end)

-- ── a refresh is not a navigation ────────────────────────────────────────────

test('refresh: :CartographUndo (and any refresh) KEEPS the lens you were in',
    function ()
    -- Reported live: undo dropped you out of the `lints` lens. The refresh that
    -- follows an undo carries the browser location through store.loc_provider, and
    -- the provider was stripping the lens for the jumplist's benefit — so a REBUILD
    -- (you never moved) inherited a JUMP's policy (you deliberately went somewhere).
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
    eq('lints', symbols.view.lens)
    local ok_r, why = require('cartograph.refresh').files({ 'm.lua' })
    ok(ok_r, tostring(why))
    eq('lints', symbols.view.lens) -- still reading what you were reading
    local rows = table.concat(vim.api.nvim_buf_get_lines(symbols.buf, 0, -1, false), ' ')
    ok(rows:find('⚑'), 'and the lens is actually RENDERED, not just recorded: ' .. rows)
    store.loc_provider = nil
    vim.cmd('close')
end)

vim.fn.delete(SCRATCH, 'rf')
