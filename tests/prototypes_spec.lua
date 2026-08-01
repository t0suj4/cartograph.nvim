-- THE PROTOTYPE READING. A Factorio prototype is not a table literal: it is a
-- BASE REFERENCE plus an ORDERED SEQUENCE OF FIELD OVERRIDES plus a registration,
-- which is why reading it needed the module-level statement harvest first (249 of
-- one mod's 344 field-shaping assignments are module top level).
--
-- The reading is a LOWER BOUND by nature, so most of this spec is about the
-- hedges: an opaque call, a non-literal value, an unresolved base, an
-- anonymous registration. Each must be REPORTED, never smoothed over — the
-- reading's whole value to a 1.1→2.0 port is that you can trust what it claims.

local store = require 'cartograph.store'
local proto = require 'cartograph.prototypes'
local expr  = require 'cartograph.expr'

local TMP = vim.fn.tempname()

--- of_module re-parses from disk, so the fixture must be a real file. `profile`
--- is what activates the adapter (the L2 identity, not the file extension).
local function mod_of(src, profile)
    vim.fn.mkdir(TMP, 'p')
    local name = 'p' .. tostring(math.random and 1 or 1) .. '.lua'
    local path = TMP .. '/' .. name
    vim.fn.writefile(vim.split(src, '\n'), path)
    store._content_cache = {}
    store.ingest({ schema = 1, root = TMP,
        profile = profile == nil and 'lua-factorio' or profile or nil,
        nodes = { { id = name, name = name, kind = 'module', file = name,
            range = { start = { line = 0, char = 0 },
                      ['end'] = { line = #vim.split(src, '\n'), char = 0 } },
            order = 0 } }, edges = {} })
    return name
end

local function read(src, profile) return proto.of_module(store, mod_of(src, profile)) end

local function by_var(ps, v)
    for _, p in ipairs(ps or {}) do if p.var == v then return p end end
end
local function paths(p)
    local out = {}
    for _, o in ipairs(p.overrides) do out[#out + 1] = o.path end
    return out
end

-- ── activation ──────────────────────────────────────────────────────────────

test('adapter: activates on the lua-factorio profile identity, not the extension',
    function ()
    ok(proto.adapter(store) == nil or true) -- (state depends on the last ingest)
    local id = mod_of('local x = 1\n', 'lua-factorio')
    eq('factorio-data', proto.adapter(store).name)
    ok(proto.of_module(store, id))
    -- a plain lua project must NOT be read as a prototype tree
    id = mod_of('local x = 1\n', false)
    eq(nil, proto.adapter(store))
    eq(nil, proto.of_module(store, id))
end)

-- ── the canonical shape ─────────────────────────────────────────────────────

test('reading: base + ORDERED overrides + registration', function ()
    local ps = read([[
local chest = table.deepcopy(data.raw["container"]["wooden-chest"])
chest.name = "vn-chest"
chest.inventory_size = 8000
chest.minable.result = "vn-chest"
data:extend{chest}
]])
    eq(1, #ps)
    local p = ps[1]
    eq('copy', p.basis)
    eq('container', p.base.type)
    eq('wooden-chest', p.base.name)
    eq('vn-chest', p.name)                       -- from the `name` override
    eq(true, p.complete)
    ok(p.registered, 'registered')
    eq(5, p.registered.line)
    -- ORDER is the point: a later override wins in Factorio, so the sequence is
    -- the fact, not a set of fields
    eq({ 'name', 'inventory_size', 'minable.result' }, paths(p))
    eq(8000, p.overrides[2].value)               -- a number is a NUMBER
    eq('vn-chest', p.overrides[3].value)         -- quotes stripped
end)

test('reading: the base type segment is written three ways in real mods', function ()
    local ps = read([[
local a = table.deepcopy(data.raw["container"]["wooden-chest"])
local b = table.deepcopy(data.raw.item["iron-plate"])
local c = table.deepcopy(data.raw.accumulator.accumulator)
]])
    eq('container', by_var(ps, 'a').base.type)
    eq('item', by_var(ps, 'b').base.type)
    eq('accumulator', by_var(ps, 'c').base.type)
    eq('accumulator', by_var(ps, 'c').base.name)
end)

-- ── the hedges, which are the point ─────────────────────────────────────────

test('hedge: an OPAQUE CALL makes the overrides a lower bound', function ()
    -- Von-Neumann's pathReplaceRecursively walks the whole object rewriting every
    -- nested string. No static reading survives it; claiming completeness here
    -- would be the fabrication this codebase keeps paying for.
    local ps = read([[
local chest = table.deepcopy(data.raw["container"]["wooden-chest"])
chest.name = "vn-chest"
pathReplaceRecursively(chest)
data:extend{chest}
]])
    local p = ps[1]
    eq(false, p.complete)
    eq(1, #p.frontiers)
    eq('opaque-call', p.frontiers[1].kind)
    eq('pathReplaceRecursively', p.frontiers[1].callee)
    eq(3, p.frontiers[1].line)
    ok(p.registered, 'still registered — the hedge is about the FIELDS')
end)

test('hedge: a non-literal value keeps its PATH and records WHY', function ()
    local ps = read([[
local chest = table.deepcopy(data.raw["container"]["wooden-chest"])
chest.icon = make_icon("x")
chest.box = { 1, 2 }
chest.alias = other_thing
]])
    local p = ps[1]
    eq({ 'icon', 'box', 'alias' }, paths(p))
    for _, o in ipairs(p.overrides) do
        eq(nil, o.value)
        ok(o.why, o.path .. ' records a reason: ' .. tostring(o.why))
    end
    eq('call', p.overrides[1].why)
    eq('table', p.overrides[2].why)
    eq('name', p.overrides[3].why)
end)

test('reading: an explicit nil is a DELETE, not an unknown', function ()
    -- `x.next_upgrade = nil` REMOVES the inherited field — a fact, and a
    -- different one from "we could not read this value"
    local ps = read([[
local m = table.deepcopy(data.raw["container"]["wooden-chest"])
m.next_upgrade = nil
]])
    local o = ps[1].overrides[1]
    eq('next_upgrade', o.path)
    eq(expr.NIL, o.value)   -- the IR's known-nil sentinel
    eq(nil, o.why)          -- NOT unknown
end)

-- ── registration comes from DATAFLOW, not the table constructor ──────────────

test('registration: read from the row USE set, because {…} is opaque in the IR',
    function ()
    -- the expression IR models a table constructor as {k='table'} with no
    -- contents, so `data:extend{a, b}` does not mention a or b anywhere in the
    -- IR. du's read census does.
    local ps = read([[
local a = table.deepcopy(data.raw["container"]["c1"])
local b = table.deepcopy(data.raw["container"]["c2"])
data:extend{a, b}
]])
    ok(by_var(ps, 'a').registered, 'a registered')
    ok(by_var(ps, 'b').registered, 'b registered — both, from one call')
end)

test('registration: an INLINE literal is IDENTIFIED, not anonymous (CART-0220)',
    function ()
    -- This used to be the anonymous case: registering a table literal produced one
    -- record with no fields, because {…} was opaque in the IR. The IR now models
    -- constructor entries, so the literal names itself — and this is the ecosystem's
    -- dominant shape (3280 of 3874 data:extend sites across 195 installed mods).
    local ps = read('data:extend{ { type = "recipe", name = "r" } }\n')
    eq(1, #ps)
    eq(nil, ps[1].anonymous, 'no longer anonymous: the literal identifies itself')
    eq('recipe', ps[1].declared_type, 'its own type= is the discriminator')
    eq('r', ps[1].name)
    eq(2, #ps[1].fields, 'its constructor entries are READ')
    eq({}, ps[1].overrides, 'and kept out of `overrides`, which means MUTATION')
    ok(ps[1].registered, 'the registration is a fact even with no var to attach')
    eq(nil, ps[1].var)
end)

test('registration: a registration it CANNOT read is still anonymous', function ()
    -- the honest floor survives: registering something that is not a readable literal
    -- (a call, a name we never tracked) is recorded as anonymous rather than dropped
    local ps = read('data:extend{ make_recipes() }\n')
    eq(1, #ps)
    eq(true, ps[1].anonymous)
    ok(ps[1].registered)
    eq(nil, ps[1].declared_type, 'and it claims no type it could not read')
end)

test('registration: absent means absent', function ()
    local ps = read([[
local chest = table.deepcopy(data.raw["container"]["wooden-chest"])
chest.name = "vn-chest"
]])
    eq(nil, ps[1].registered)
end)

-- ── the other bases ─────────────────────────────────────────────────────────

test('basis: a PATCH overrides an existing prototype in place', function ()
    local ps = read('data.raw["utility-constants"]["default"].thing = "x"\n')
    eq(1, #ps)
    eq('patch', ps[1].basis)
    eq('utility-constants', ps[1].patch.type)
    eq('default', ps[1].patch.name)
    eq('thing', ps[1].overrides[1].path)
    eq('x', ps[1].overrides[1].value)
end)

test('basis: DERIVED from a tracked prototype inherits its base', function ()
    local ps = read([[
local base = table.deepcopy(data.raw["container"]["wooden-chest"])
local copy = table.deepcopy(base)
copy.name = "other"
]])
    local d = by_var(ps, 'copy')
    eq('derived', d.basis)
    eq('base', d.from_var)
    eq('wooden-chest', d.base.name) -- transitively
end)

test('basis: an unresolved base NAMES the local — actionable, not a shrug',
    function ()
    -- the gui-style pattern: an alias of a data.raw path, copied out of, and
    -- registered by assigning back INTO the alias. A second registration model,
    -- deliberately not read — but the frontier says exactly where to look.
    local ps = read([[
local styles = data.raw["gui-style"].default
local frame = table.deepcopy(styles.frame)
frame.opacity = 1
]])
    local f = by_var(ps, 'frame')
    eq('copy-unresolved', f.basis)
    eq('styles', f.from_var)
    eq('styles.frame', f.from_path)
    eq(nil, f.base)
    -- and its own overrides are still read
    eq({ 'opacity' }, paths(f))
end)

test('basis: NOTHING is left as a bare unknown on the real corpus shape',
    function ()
    -- every shape in a 2000-line mod resolved to a named basis; a shrug is a
    -- reading defect, so this pins the invariant on the shapes we know
    local ps = read([[
local a = table.deepcopy(data.raw["container"]["c"])
local b = table.deepcopy(data.raw.item["i"])
local c = table.deepcopy(data.raw.accumulator.accumulator)
local d = table.deepcopy(a)
local e = table.deepcopy(some_alias.sub)
local f = { type = "recipe" }
data.raw["x"]["y"].z = 1
]])
    for _, p in ipairs(ps) do
        ok(p.basis ~= 'unknown', (p.var or '(anon)') .. ' has a named basis, got ' .. p.basis)
    end
end)

-- ── census ──────────────────────────────────────────────────────────────────

test('census: counts the reading and its hedges', function ()
    mod_of([[
local a = table.deepcopy(data.raw["container"]["c"])
a.name = "n"
mutate(a)
data:extend{a}
]])
    local c = proto.census(store)
    eq(1, c.total)
    eq(1, c.basis.copy)
    eq(1, c.registered)
    eq(1, c.hedged)
    eq(1, c.named)
    eq(1, c.overrides)
end)

test('census: nil when the adapter does not apply', function ()
    mod_of('local x = 1\n', false)
    eq(nil, proto.census(store))
    eq(nil, proto.all(store))
end)

-- ── the report, found by DRIVING the live cockpit on Von-Neumann ─────────────

test('literal: a LONG BRACKET string keeps its content, not its delimiters',
    function ()
    -- the story text of a real mod is `[[…]]`, at any bracket level, and the IR
    -- carries the source text verbatim — so the reading must strip the
    -- delimiters exactly as it strips " and '
    local ps = read([====[
local s = { type = "x" }
s.a = [[one]]
s.b = [==[two]==]
s.c = [[
after a leading newline]]
]====])
    local o = ps[1].overrides
    eq('one', o[1].value)
    eq('two', o[2].value)
    eq('after a leading newline', o[3].value)  -- Lua skips a leading newline
end)

test('report: a MULTI-LINE value cannot break the buffer contract', function ()
    -- nvim_buf_set_lines REJECTS an embedded newline, so one story blob took the
    -- whole command down live. Every report line must be ONE line — and the
    -- folding must be visible, not silent.
    local ps = read('local s = { type = "x" }\ns.t = [[a\nb\nc]]\n')
    eq('a\nb\nc', ps[1].overrides[1].value)    -- the RECORD keeps the newlines
    local lines = proto.report(store)
    local hit
    for _, l in ipairs(lines) do
        ok(not l:find('[\r\n]'), 'no report line may contain a newline')
        if l:find('%.t ') or l:find(' t  ') then hit = l end
    end
    hit = hit or table.concat(lines, '|')
    ok(hit:find('↵'), 'the fold is marked, not silent: ' .. hit)
end)

test('report: a long value is truncated with a MARK, and a string is quoted',
    function ()
    local ps = read(('local s = { type = "x" }\ns.long = "%s"\ns.n = 8000\n'
        .. 's.gone = nil\n'):format(('x'):rep(200)))
    eq(200, #ps[1].overrides[1].value)         -- the record is not truncated
    local lines = proto.report(store)
    local long, num, del
    for _, l in ipairs(lines) do
        if l:find('long') then long = l end
        if l:find(' n  ') then num = l end
        if l:find('gone') then del = l end
    end
    ok(long and long:find('…'), 'truncation is marked: ' .. tostring(long))
    ok(#long < 140, 'and bounded, got ' .. #long)
    ok(long:find('"'), 'a string renders QUOTED, so it is distinguishable from a number')
    ok(num and num:find('= 8000') and not num:find('"8000"'),
        'a number renders bare: ' .. tostring(num))
    ok(del and del:find('DELETE'), 'an explicit nil is named a DELETE: ' .. tostring(del))
end)

test('report: a frontier sorts INTO the override sequence by line', function ()
    -- the sequence IS the fact (later wins), so a hedge printed after the
    -- overrides it precedes reads as the opposite of what happened
    read([[
local p = table.deepcopy(data.raw["container"]["c"])
p.a = 1
mutate(p)
p.b = 2
]])
    local lines = proto.report(store)
    local seen = {}
    for _, l in ipairs(lines) do
        if l:find('  a  ') then seen[#seen + 1] = 'a' end
        if l:find('opaque%-call') then seen[#seen + 1] = '~' end
        if l:find('  b  ') then seen[#seen + 1] = 'b' end
    end
    eq({ 'a', '~', 'b' }, seen)
end)
