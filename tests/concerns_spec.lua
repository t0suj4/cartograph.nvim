-- THE CONCERN REGISTRY. The four RELATION altitudes (callers/occs/regfor/
-- refused) each open-coded the same five answers in five different places, and
-- every one of those lists was incomplete for at least one of them
-- ([[cartograph-concern-layering]]). This spec holds the declaration.
--
-- Two things are asserted that a spec normally cannot reach: the ascend INVERSE
-- (the dispatch is a closure inside attach(), but the declared function is not),
-- and the hover CLASS (membership, not the body — a spec that called hover_node
-- directly would pass against exactly the bug that made it unreachable).

local store    = require 'cartograph.store'
local symbols  = require 'cartograph.panes.symbols'
local concerns = require 'cartograph.panes.concerns'

local SEP = '\31'

local function R(l1, l2)
    return { start = { line = l1, char = 0 }, ['end'] = { line = l2 or l1, char = 0 } }
end
local function fn(id, name, file, l1)
    return { id = id, name = name, kind = 'function', file = file or 'm.lua',
        range = R(l1 or 0), order = l1 or 0 }
end
local function mod(file)
    return { id = file, name = file, kind = 'module', file = file, range = R(0), order = 0 }
end

local function reset(nodes, view)
    store.ingest({ schema = 1, root = '/x', nodes = nodes, edges = {} })
    symbols.win, symbols.buf = nil, nil
    symbols.line_node, symbols.line_about, symbols.line_kind = {}, {}, {}
    symbols.line_site, symbols.line_group, symbols.line_file = {}, {}, {}
    symbols.view = view or { level = 'files' }
end

--- A store stub for empty_of: only the capability predicate matters.
--- A store stub for empty_of. It has to be capable w.r.t. EVERY precondition a
--- concern can have, not just the thin index: `proto`'s unavailability is the
--- absence of a DATA STAGE, so the stub carries a profile that has one. A stub
--- that is accidentally incapable makes the computed-empty half untestable.
local function stub(index_only)
    return { data = { root = '/proj', profile = 'lua-factorio' },
        is_index_only = function () return index_only end }
end

-- ── the declaration is TOTAL ────────────────────────────────────────────────

test('registry: every entry declares all five answers (the totality fence)',
    function ()
    local n = 0
    for level, e in pairs(concerns.REGISTRY) do
        n = n + 1
        ok(type(e.view_key) == 'string', level .. ' declares view_key')
        ok(type(e.subject) == 'function', level .. ' declares subject')
        ok(type(e.ascend) == 'function', level .. ' declares ascend (THE INVERSE)')
        ok(e.hover == 'node' or e.hover == 'site', level .. ' declares a hover class')
        ok(type(e.empty) == 'table' and e.empty.computed, level .. ' declares computed-empty')
        ok(type(e.empty.uncomputed) == 'function',
            level .. ' declares WHY it might have no answer')
    end
    -- callers, occs, regfor, refused + proto (the compartment pilot) + lintact
    eq(6, n)
end)

test('registry: lintact is about its fn and returns to it', function ()
    local key = 'f.lua::update@3\031120\031concat-in-loop'
    eq('f.lua::update@3', concerns.subject_of('lintact', key))
    local level, back = concerns.of('lintact').ascend(key)
    eq('fn', level)
    eq('f.lua::update@3', back) -- the finding hangs below the function it is in
end)

test('registry: lintact\'s unavailability is its OWN, not the shared one', function ()
    -- rung-0 lints ride the expression IR, which a thin index can re-derive per
    -- file, so binding this concern to needs_edges would refuse an answer it has
    ok(concerns.of('lintact').empty.uncomputed ~= concerns.needs_edges,
        'lintact must not inherit the call-graph precondition')
    eq(nil, concerns.of('lintact').empty.uncomputed(stub(true)))
end)

test('registry: the containment/data altitudes are deliberately NOT concerns',
    function ()
    for _, level in ipairs({ 'files', 'file', 'fn', 'block', 'region',
                             'states', 'state', 'lit', 'live', 'ws', 'var', 'tbl' }) do
        eq(nil, concerns.of(level))
    end
end)

-- ── subject: what the altitude is ABOUT ─────────────────────────────────────

test('subject_of: callers and regfor are about their key', function ()
    eq('m.lua::f', concerns.subject_of('callers', 'm.lua::f'))
    eq('m.lua::f', concerns.subject_of('regfor', 'm.lua::f'))
end)

test('subject_of: occs is about the USING fn (the key tail), not the entity',
    function ()
    eq('m.lua::user',
        concerns.subject_of('occs', 'ref' .. SEP .. 'm.lua::ent' .. SEP .. 'm.lua::user'))
end)

test('subject_of: refused is about the ENCLOSING fn (the key head)', function ()
    -- THE BUG: M.subject omitted `refused` entirely while the ascend handler
    -- derived this exact answer from this exact key one line away, so mark
    -- refused on every refusal row that was not a candidate.
    eq('m.lua::f', concerns.subject_of('refused', 'm.lua::f' .. SEP .. '10' .. SEP .. 'callee'))
end)

test('subject_of: a malformed key is nil, never the empty string', function ()
    -- '' is truthy in lua: every caller would then ask store.node('')
    eq(nil, concerns.subject_of('occs', nil))
    eq(nil, concerns.subject_of('refused', ''))
    eq(nil, concerns.subject_of('nonsense', 'x'))
end)

test('subject: the pane answers at the refused altitude (regression)', function ()
    reset({ fn('m.lua::f', 'f') },
        { level = 'refused', refused = 'm.lua::f' .. SEP .. '10' .. SEP .. 'callee' })
    eq('m.lua::f', symbols.subject())
    eq(nil, symbols.subject('def')) -- but it is not a DEF altitude
end)

-- ── ascend: THE INVERSE, declared ───────────────────────────────────────────

test('ascend: the relation altitudes hang below their subject fn', function ()
    for _, level in ipairs({ 'callers', 'regfor' }) do
        local l, k = concerns.of(level).ascend('m.lua::f')
        eq('fn', l); eq('m.lua::f', k)
    end
    local l, k = concerns.of('refused')
        .ascend('m.lua::f' .. SEP .. '10' .. SEP .. 'callee')
    eq('fn', l); eq('m.lua::f', k)
end)

test('ascend: occs returns to the relation it was reached FROM', function ()
    -- the key records which one: h must not guess
    local l, k = concerns.of('occs')
        .ascend('var' .. SEP .. 'm.lua::v' .. SEP .. 'm.lua::user')
    eq('var', l); eq('m.lua::v', k)
    l, k = concerns.of('occs')
        .ascend('ref' .. SEP .. 'm.lua::ent' .. SEP .. 'm.lua::user')
    eq('callers', l); eq('m.lua::ent', k)
end)

test('ascend: a malformed occs key refuses rather than ascending to nothing',
    function ()
    eq(nil, (concerns.of('occs').ascend('')))
    eq(nil, (concerns.of('occs').ascend('ref' .. SEP .. SEP .. 'x')))
end)

-- ── hover: the class is DERIVED from the declarations ───────────────────────

test('hover: the node-row altitudes come from the registry, not a hand list',
    function ()
    local levels = concerns.node_hover_levels()
    ok(levels.regfor, 'a registrant row is a module NODE row')
    ok(levels.refused, 'a candidate row is a def NODE row')
    ok(not levels.callers, 'a caller row is a SITE row (the site renderer previews it)')
    ok(not levels.occs, 'an occurrence row is a SITE row')
    -- and the pane's class is that, plus the non-concern altitudes
    ok(symbols.NODE_HOVER.regfor, 'the pane picked regfor up from the registry')
    ok(symbols.NODE_HOVER.ws, 'and keeps the non-concern members')
end)

test('hover: a regfor row previews the registering MODULE', function ()
    -- THE BUG: hover_node read line_node alone, and a regfor row carries only
    -- line_about — so the whole altitude previewed nothing. A module node's id
    -- IS its file path, so the row is about a real node like any other.
    reset({ fn('m.lua::f', 'f'), mod('reg.lua') }, { level = 'regfor', regfor = 'm.lua::f' })
    store.set_focus('m.lua::f')
    store.set_context(nil)
    symbols.line_about = { [2] = 'reg.lua' }
    eq('reg.lua', symbols.hover_node(2))
    eq('reg.lua', store.context and store.context.node)
end)

test('hover: line_node still wins over line_about (what a row IS beats what it is about)',
    function ()
    reset({ fn('m.lua::f', 'f'), fn('m.lua::g', 'g', 'm.lua', 5) }, { level = 'refused' })
    store.set_focus('m.lua::f')
    symbols.line_node  = { [2] = 'm.lua::g' }
    symbols.line_about = { [2] = 'm.lua::f' }
    eq('m.lua::g', symbols.hover_node(2))
end)

-- ── empty: computed-and-none vs never-computed ──────────────────────────────

test('empty: a computed absence states what it MEANS', function ()
    local note, why = concerns.empty_of('callers', stub(false))
    eq(nil, why)
    ok(note:find('entry point', 1, true), 'the note explains the absence: ' .. note)
end)

test('empty: every concern has a real computed note (occs had NONE)', function ()
    for level in pairs(concerns.REGISTRY) do
        local note, why = concerns.empty_of(level, stub(false))
        eq(nil, why)
        ok(note and #note > 12, level .. ' says something: ' .. tostring(note))
    end
end)

test('empty: an EDGE-derived concern is unavailable on a thin index, and says so',
    function ()
    -- THE FABRICATION: index-only carries every file's defs and 4 edges in total
    -- (import only — no ref/reg/use, 0 calls), so a fn with 4 callers on the full
    -- graph rendered "(no callers found — entry point, or dynamically
    -- dispatched)". A manufactured fact: the pane never asked.
    local n = 0
    for level, e in pairs(concerns.REGISTRY) do
        if e.empty.uncomputed == concerns.needs_edges then
            n = n + 1
            local note, why = concerns.empty_of(level, stub(true))
            ok(why, level .. ' reports a reason under index-only')
            eq(note, why) -- one call answers both: the text IS the reason
            ok(why:find('index%-only'), level .. ' names the mode: ' .. why)
            ok(why:find('/proj', 1, true), level .. ' points at the full open')
            ok(why ~= e.empty.computed, level .. ' does NOT reuse the computed note')
        end
    end
    eq(4, n) -- callers, occs, regfor, refused: the four built from edges
end)

test('empty: a concern with a DIFFERENT precondition reports its own reason',
    function ()
    -- The pilot broke the old assumption that every unavailability is the thin
    -- index. `proto` is unavailable when the project has no DATA STAGE, and — the
    -- interesting half — it is AVAILABLE on a thin index, because the prototype
    -- reading RE-PARSES module rows instead of reading edges. A fence that
    -- assumed one cause would have forced a false reason here.
    local no_stage = { data = { root = '/proj' },   -- no profile => no adapter
        is_index_only = function () return false end }
    local note, why = concerns.empty_of('proto', no_stage)
    ok(why, 'proto reports a reason when there is no data stage')
    eq(note, why)
    ok(why:find('data stage'), 'and names what is missing: ' .. why)
    ok(why ~= concerns.REGISTRY.proto.empty.computed, 'not the computed note')

    local n2, w2 = concerns.empty_of('proto', stub(true)) -- index-only, has a stage
    eq(nil, w2)
    ok(n2:find('overrides'), 'on a thin index it is COMPUTABLE, so the note is the'
        .. ' computed one: ' .. tostring(n2))
end)

test('empty: not a concern -> nil (the caller keeps its own note)', function ()
    eq(nil, concerns.empty_of('files', stub(true)))
    eq(nil, concerns.empty_of('fn', stub(false)))
end)

-- ── the fabrication, end to end through the RENDERER ────────────────────────

test('render: the callers altitude REFUSES on a thin index instead of claiming none',
    function ()
    -- The declaration is only half the fix; this asserts the rendered pane. On
    -- the thin index a fn with real callers used to read as a confident
    -- "(no callers found — entry point, or dynamically dispatched)" with a "(0)"
    -- count in the header. Both were manufactured.
    store.ingest({ schema = 1, root = '/proj', index_only = true,
        nodes = { fn('m.lua::f', 'f') }, edges = {} })
    ok(store.is_index_only(), 'the graph reports itself thin')
    local buf = vim.api.nvim_create_buf(false, true)
    symbols.buf, symbols.win = buf, nil
    symbols.view = { level = 'callers', callers = 'm.lua::f' }
    symbols.render()
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    ok(text:find('unavailable', 1, true),
        'the header says unavailable, not a count: ' .. text)
    ok(text:find('index%-only'), 'the row states the reason: ' .. text)
    ok(not text:find('entry point', 1, true),
        'and never the computed note: ' .. text)
    ok(not text:find('(0)', 1, true), 'no fabricated zero: ' .. text)
    vim.api.nvim_buf_delete(buf, { force = true })
    symbols.buf = nil
end)

test('render: a full graph with genuinely no callers still says what that MEANS',
    function ()
    -- the other half of typed-empty: refusing everywhere would be its own lie
    store.ingest({ schema = 1, root = '/proj',
        nodes = { fn('m.lua::f', 'f') }, edges = {} })
    ok(not store.is_index_only())
    local buf = vim.api.nvim_create_buf(false, true)
    symbols.buf, symbols.win = buf, nil
    symbols.view = { level = 'callers', callers = 'm.lua::f' }
    symbols.render()
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    ok(text:find('entry point', 1, true), 'the computed note: ' .. text)
    ok(not text:find('index%-only'), 'no spurious refusal: ' .. text)
    vim.api.nvim_buf_delete(buf, { force = true })
    symbols.buf = nil
end)

test('the guard belongs to the SURFACE: the source pane shares it too', function ()
    -- navaudit's check A found this second instance while it was being written:
    -- source.lua's jump reported "no known callee under the cursor" — a CLAIM
    -- about the call graph — on a thin index that has none. The unit of the
    -- honesty guard is the surface, not the verb.
    local src = require 'cartograph.panes.source'
    ok(type(src.resolve_jump) == 'function', 'the resolver is public')
    -- resolve_jump itself stays pure (nil = nothing here); the CALLER decides
    -- how to say so, which is why the guard reads from concerns
    store.ingest({ schema = 1, root = '/proj', index_only = true,
        nodes = { fn('m.lua::f', 'f') }, edges = {} })
    eq(nil, src.resolve_jump(store.node('m.lua::f'), 0, 0, 'whatever'))
    ok(concerns.needs_edges(store), 'and the surface can say WHY it is nil')
end)

test('empty: needs_edges is exported so `var` can share the fix', function ()
    -- var is not a concern entry (its subject and inverse are structural) but
    -- its rows come from the same use edges, so it must not be left fabricating
    ok(concerns.needs_edges(stub(true)), 'unavailable on the thin index')
    eq(nil, concerns.needs_edges(stub(false)))
end)
