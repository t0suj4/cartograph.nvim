-- MODULE-LEVEL STATEMENT HARVEST. `expr.of` is function-scoped — it locates the
-- enclosing function node and walks its body — so it returns nil for a module,
-- and the whole config-as-code world was invisible to the expression layer.
-- MEASURED on a Factorio 1.1 mod: `harvest_row` parsed 344/344 of its
-- field-shaping assignments perfectly while the graph represented 0, and 249 of
-- those sites (72%) were module top level ([[cartograph-bench]] item 0). The hole
-- was never the parser; it was the absence of a DRIVER.

local store = require 'cartograph.store'
local expr  = require 'cartograph.expr'

local TMP = vim.fn.tempname()

--- Write a real file and ingest a graph whose module node points at it: of_module
--- re-parses from disk through store.content, so a synthetic node is not enough.
local function withfile(name, src)
    vim.fn.mkdir(TMP, 'p')
    local path = TMP .. '/' .. name
    vim.fn.writefile(vim.split(src, '\n'), path)
    local nlines = #vim.split(src, '\n')
    store.ingest({ schema = 1, root = TMP, nodes = {
        { id = name, name = name, kind = 'module', file = name,
          range = { start = { line = 0, char = 0 },
                    ['end'] = { line = nlines, char = 0 } }, order = 0 },
    }, edges = {} })
    return name
end

--- every harvested lhs path on a module's rows, as full dotted strings.
--- Uses expr.dotted rather than reading `.b.n` by hand: the base of a NESTED
--- path is itself a field node, so hand-walking one level reports
--- `minable.result` for `chest.minable.result` and looks like a harvest gap when
--- it is only a lossy reader.
local function lhs_paths(eo)
    local out = {}
    for _, st in ipairs(eo.fl.stmts or {}) do
        for _, l in ipairs((st.expr or {}).lhs or {}) do
            local d = expr.dotted(l)
            if d then out[#out + 1] = d end
        end
    end
    return out
end

local function has(list, want)
    for _, v in ipairs(list) do if v == want then return true end end
    return false
end

-- ── the hole, and that it is closed ─────────────────────────────────────────

test('of_module: expr.of is nil for a module — that IS the hole', function ()
    local id = withfile('m.lua', 'local t = {}\nt.name = "x"\n')
    eq(nil, expr.of(store, id))          -- function-scoped, by design
    ok(expr.of_module(store, id), 'of_module answers where of cannot')
end)

test('of_module: harvests TOP-LEVEL field overrides — the prototype shape',
    function ()
    -- exactly how a Factorio prototype is built: copy a base, then override
    -- fields one statement at a time. None of it is inside a function.
    local id = withfile('proto.lua', [[
local chest = table.deepcopy(data.raw["container"]["wooden-chest"])
chest.name = "vn-chest"
chest.inventory_size = 8000
chest.minable.result = "vn-chest"
data:extend{chest}
]])
    local eo = expr.of_module(store, id)
    local paths = lhs_paths(eo)
    ok(has(paths, 'chest.name'), 'name override: ' .. vim.inspect(paths))
    ok(has(paths, 'chest.inventory_size'), 'scalar override')
    ok(has(paths, 'chest.minable.result'),
        'a NESTED path survives WHOLE — 155 of the mod\'s 344 are multi-segment')
end)

test('of_module: every row carries an .expr (the harvest is total)', function ()
    local id = withfile('mixed.lua', [[
local a = 1
a = a + 1
t.x = "s"
call(a)
for i = 1, 3 do t.y = i end
if a then t.z = 2 end
]])
    local eo = expr.of_module(store, id)
    local rows, harvested = 0, 0
    for _, st in ipairs(eo.fl.stmts) do
        rows = rows + 1
        if st.expr then harvested = harvested + 1 end
    end
    ok(rows >= 6, 'the sequence has rows: ' .. rows)
    eq(rows, harvested) -- 601/601 on the real mod; no row is left unparsed
end)

test('of_module: a nested function body stays OPAQUE — one row, not its insides',
    function ()
    -- a module's statement list means its OWN statements; the insides of a
    -- top-level function are M.of's job, and double-counting them would make
    -- module rows and fn rows overlap
    local id = withfile('withfn.lua', [[
local function helper(x)
    x.inside = 1
    x.alsoinside = 2
end
outer.field = 3
]])
    local paths = lhs_paths(expr.of_module(store, id))
    ok(has(paths, 'outer.field'), 'the top-level assignment: ' .. vim.inspect(paths))
    ok(not has(paths, 'x.inside'), 'the fn body is NOT walked')
    ok(not has(paths, 'x.alsoinside'), 'nor its second statement')
end)

test('of_module: a sequence has no parameters (a chunk is not a function)',
    function ()
    local id = withfile('p.lua', 'x.y = 1\n')
    eq(0, #expr.of_module(store, id).fl.params)
end)

-- ── refusals: it must not claim more than M.of ──────────────────────────────

test('of_module: refuses a non-module node', function ()
    withfile('n.lua', 'x.y = 1\n')
    store.ingest({ schema = 1, root = TMP, nodes = {
        { id = 'n.lua::f', name = 'f', kind = 'function', file = 'n.lua',
          range = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } },
          order = 0 },
    }, edges = {} })
    eq(nil, expr.of_module(store, 'n.lua::f'))
    eq(nil, expr.of_module(store, 'no-such-id'))
end)

test('of_module: refuses a language M.of would also refuse', function ()
    -- the supported set is EXT, shared with M.of, so this never claims a
    -- language the function-scoped entry cannot handle
    local id = withfile('conf.unknownext', 'x.y = 1\n')
    eq(nil, expr.of_module(store, id))
end)

test('of_module: a file that is gone yields nil, not an error', function ()
    local id = withfile('gone.lua', 'x.y = 1\n')
    vim.fn.delete(TMP .. '/gone.lua')
    store._content_cache = {} -- content is stamp-cached; force the re-read
    eq(nil, expr.of_module(store, id))
end)

-- ── the FREE SELF-GATE, on the new rows ─────────────────────────────────────

test('of_module: module rows pass the expr self-gate', function ()
    -- expr.reads(row) is an INDEPENDENT derivation of du's use∪rmw over the same
    -- node, so agreement is evidence the harvest is CONSISTENT rather than merely
    -- non-empty. MEASURED on the Factorio mod: 601 module rows, 0 disagreements.
    -- (cartograph's own tree: 11800 module rows, 2 disagreements, both C
    -- file-scope declarations — a PRE-EXISTING over-report of a C declarator's
    -- name as a read, which fires inside functions too (`int t = a + counter;`).
    -- C expression coverage is its own project, like Java's; see expr.lua.)
    local id = withfile('gated.lua', [[
local base = table.deepcopy(other.thing)
base.name = "x"
base.size = base.size + 1
local n = #base.list
for _, v in ipairs(base.list) do base.total = base.total + v end
if base.flag and n > 0 then base.ok = true end
data:extend{base}
]])
    local eo = expr.of_module(store, id)
    local bad = expr.gate(eo.fl, eo.lang)
    local shown = {}
    for _, b in ipairs(bad) do
        shown[#shown + 1] = ('line %d missing=[%s] extra=[%s]'):format(
            (b.line or 0) + 1, table.concat(b.missing, ','), table.concat(b.extra, ','))
    end
    eq(0, #bad, table.concat(shown, ' | '))
end)

-- ── the flow-level seam ─────────────────────────────────────────────────────

test('flow: cfg.seq regions the node ITSELF, fn_body finds nothing there',
    function ()
    local flow = require 'cartograph.flow'
    local src = 'a.b = 1\nc.d = 2\n'
    local rootn = vim.treesitter.get_string_parser(src, 'lua'):parse()[1]:root()
    eq(0, #flow.build(rootn, src, {}).stmts)         -- no body field -> nothing
    eq(2, #flow.build(rootn, src, { seq = true }).stmts)
end)
