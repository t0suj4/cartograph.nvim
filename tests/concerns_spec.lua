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
    -- callers, occs, regfor, refused + proto (the compartment pilot) + the three
    -- lint altitudes: lintact (one finding's actions), suppressed and unread (the
    -- two doors behind the lints lens's counts)
    eq(9, n) -- + axis (CART-0482: one entry for the whole declared family)
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
    ok(levels.refused, 'a candidate row is a def NODE row')
    ok(not levels.callers, 'a caller row is a SITE row (the site renderer previews it)')
    ok(not levels.occs, 'an occurrence row is a SITE row')
    ok(not levels.regfor, 'a registrant row is a SITE row too: it names a module,'
        .. ' but it is ANCHORED where the registration is written')
    -- and the pane's class is that, plus the non-concern altitudes
    ok(symbols.NODE_HOVER.refused, 'the pane picked refused up from the registry')
    ok(symbols.NODE_HOVER.ws, 'and keeps the non-concern members')
end)

test('hover: hover_node falls back to what a row is ABOUT when it is not a node',
    function ()
    -- THE ORIGINAL BUG: hover_node read line_node alone, so a row carrying only
    -- line_about previewed NOTHING. The fallback is the fix and it is still the
    -- mechanism for every node-hover altitude whose rows are not themselves defs.
    reset({ fn('m.lua::f', 'f'), mod('reg.lua') }, { level = 'ws' })
    store.set_focus('m.lua::f')
    store.set_context(nil)
    symbols.line_about = { [2] = 'reg.lua' }
    eq('reg.lua', symbols.hover_node(2))
    eq('reg.lua', store.context and store.context.node)
end)

test('regfor: a registrant row is anchored at the REGISTRATION, not the file head',
    function ()
    -- reported: "the registered by rows preview the beginning of the file, it's
    -- rather confusing". A module node's range starts at the top of its file, so
    -- previewing the row as a NODE showed line 1 -- while the row's own label
    -- prints `reg.lua:8` and line_site has held the exact range all along. The
    -- class is the fix; this pins the row carrying what a site preview needs.
    reset({ fn('m.lua::f', 'f'), mod('reg.lua') },
        { level = 'regfor', regfor = 'm.lua::f' })
    store.reg_by['m.lua::f'] = { { from = 'reg.lua', at = { R(7), R(9) } } }
    symbols.create(); symbols.win = nil -- a buffer with no window: the row MAPS
    symbols.render()                    -- are what this asserts, not the pixels
    local srow
    for r = 1, 8 do if symbols.line_site[r] then srow = r end end
    ok(srow, 'the registrant row carries a site')
    local st = symbols.line_site[srow]
    eq('reg.lua', st.file)
    eq(7, st.line, 'the line the registration is written on, not 0')
    eq(2, #st.ranges, 'and EVERY occurrence, since one module can register twice')
    ok(st.reg, 'marked as a registration site')
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
    eq(5, n) -- callers, occs, regfor, refused + axis: built from edges
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

-- ── THE CONTAINMENT DECLARATION (CART-0481) ─────────────────────────────────
-- What ENCLOSES each altitude used to be an eleven-branch if/elseif inside the
-- ascend keymap, i.e. unreachable from a spec and unfenced by anything. Two of
-- those branches were written the same day `H` was, and one altitude (`syms`)
-- had NO branch at all — invisible because the trail always answers before
-- containment does. The registry is the declaration; navaudit's disposition D
-- fences membership; this holds the ANSWERS.
local altreg = require 'cartograph.panes.altitudes'

test('altitudes: every entry is exactly one of up / root', function ()
    local nup, nroot = 0, 0
    for level, e in pairs(altreg.REGISTRY) do
        ok(not (e.up and e.root), level .. ' declares one of up/root, not both')
        ok(e.up or e.root, level .. ' declares something')
        if e.up then
            nup = nup + 1
            ok(type(e.up) == 'function', level .. ' declares up as a function')
        else
            nroot = nroot + 1
            ok(type(e.root) == 'string', level .. ' says WHY it is a root')
        end
    end
    eq(20, nup) -- + axis, folded in from its concern
    eq(3, nroot) -- files, protos, ws
end)

test('altitudes: a relation altitude does NOT restate its inverse', function ()
    -- concerns.ascend is the same fact; a hand-written entry here would shadow
    -- it and the two would drift. They are folded in from that declaration.
    for level in pairs(concerns.REGISTRY) do
        ok(altreg.of(level).from_concern,
            level .. ' takes its containment from concerns.ascend')
    end
    local lvl, key, anchor = altreg.of('callers').up('m.lua::f')
    eq('fn', lvl); eq('m.lua::f', key); eq(2, anchor.row)
end)

test('altitudes: a ranged key surfaces onto the statement that holds it', function ()
    reset({ mod('m.lua'), fn('m.lua::f', 'f', 'm.lua', 3) })
    -- block and syms spell their keys the same way, deliberately: one answer
    for _, level in ipairs({ 'block', 'syms' }) do
        local lvl, key, anchor = altreg.of(level).up('m.lua::f' .. SEP .. '9' .. SEP
            .. '0' .. SEP .. '-1' .. SEP .. '-1', store)
        eq('fn', lvl, level .. ' surfaces to its function')
        eq('m.lua::f', key)
        eq(10, anchor.line, level .. ' lands on the 1-based line of its range')
    end
    -- a key whose owner is gone surfaces to the tree rather than an empty view
    eq('files', altreg.of('block').up('m.lua::gone' .. SEP .. '2', store))
end)

test('altitudes: a value tree pops ONE path segment, then leaves the tree',
    function ()
    reset({ mod('m.lua'), { id = 'm.lua::var:cfg@1', name = 'cfg', kind = 'var',
        file = 'm.lua', range = R(1), order = 1 } })
    local key = 'm.lua::var:cfg@1' .. SEP .. 'a' .. SEP .. 'b'
    local lvl, up, anchor = altreg.of('lit').up(key, store)
    eq('lit', lvl)
    eq('m.lua::var:cfg@1' .. SEP .. 'a', up, 'one segment up')
    eq(key, anchor.lit, 'with the cursor on the row we came from')
    -- at the root the tree is left entirely: the var's own place in the file
    lvl, up = altreg.of('lit').up('m.lua::var:cfg@1', store)
    eq('file', lvl); eq('m.lua', up)
    -- live rows ARE lit rows, and answer identically — in their OWN tree
    local llvl, lup = altreg.of('live').up(key, store)
    eq('live', llvl); eq('m.lua::var:cfg@1' .. SEP .. 'a', lup)
end)

test('altitudes: a module surfaces to its file with no row of its own', function ()
    reset({ mod('m.lua') })
    local lvl, key, anchor = altreg.up_of_node('m.lua', store)
    eq('file', lvl); eq('m.lua', key)
    eq(nil, anchor, 'a module has no row inside its own file view')
end)

-- ── THE AXIS REGISTRY (CART-0482) ───────────────────────────────────────────
-- Four kinds chosen to DIFFER, so a view designed against `callers` alone
-- cannot pass for general: node rows, file rows, site rows, and a transitive
-- cone. Both arms of the presentation A/B render from these declarations, so
-- what is asserted here is what both arms show.
local axreg = require 'cartograph.panes.axes'

test('axes: every declaration is total, and the kinds differ', function ()
    local kinds = {}
    for _, name in ipairs(axreg.ORDER) do
        local e = axreg.AXES[name]
        ok(e, name .. ' is in ORDER and declared')
        ok(type(e.glyph) == 'string' and #e.glyph > 0, name .. ' has a glyph')
        ok(type(e.label) == 'string', name .. ' has a label')
        ok(e.on == 'fn' or e.on == 'module' or e.on == 'var',
            name .. ' declares its subject kind')
        ok(type(e.rows) == 'function', name .. ' declares rows')
        kinds[e.on] = true
    end
    eq(6, #axreg.ORDER)
    ok(kinds.fn and kinds.module and kinds.var, 'all three subject kinds are covered')
    -- the cone declares that COUNTING it costs a traversal: the doors arm pays
    -- that on every render, which is half of what the A/B measures
    ok(axreg.AXES.reaches.walk and axreg.AXES.reached_by.walk,
        'the transitive axes declare themselves walks')
    ok(not axreg.AXES.callees.walk, 'a slice axis does not')
end)

test('axes: the inverse is declared, not derived from the name', function ()
    eq('imported_by', axreg.AXES.imports.inverse)
    eq('imports', axreg.AXES.imported_by.inverse)
    eq('reached_by', axreg.AXES.reaches.inverse)
    eq('callers', axreg.AXES.callees.inverse) -- the exemplar it mirrors
end)

test('axes: of() offers only the axes that hang off THIS subject', function ()
    local fn = { kind = 'function' }
    local var = { kind = 'var' }
    local mod = { kind = 'module' }
    eq(3, #axreg.of(fn, true))   -- callees, reaches, reached_by
    eq(2, #axreg.of(mod, true))  -- imports, imported by
    eq(1, #axreg.of(var, true))  -- writes
    eq(0, #axreg.of({ kind = 'region' }, true))
    eq('callees', axreg.of(fn, true)[1])
end)

test('axes: the DEFAULT band is the cheap half, and says what it holds back',
    function ()
    -- the line is `walk`, not taste: a door renders on every cursor move and
    -- shows its count, so the axes whose count is a TRAVERSAL are the ones the
    -- narrow band leaves out (measured 6.08 vs 4.49 ms/render on mantis).
    local fn = { kind = 'function' }
    eq(1, #axreg.of(fn), 'only callees is cheap enough for the default band')
    eq('callees', axreg.of(fn)[1])
    local held = axreg.held_back(fn)
    eq(2, #held)
    eq('reaches', held[1]); eq('reached_by', held[2])
    -- a subject with no expensive axis holds nothing back, so no toggle row
    eq(nil, axreg.held_back({ kind = 'var' }))
    eq(nil, axreg.held_back({ kind = 'module' }))
end)

test('axes: a key round-trips, and an unknown axis yields no rows', function ()
    local key = axreg.key('callees', 'm.lua::f')
    local name, subject = axreg.split(key)
    eq('callees', name); eq('m.lua::f', subject)
    reset({ mod('m.lua'), fn('m.lua::f', 'f') })
    eq(nil, axreg.rows(axreg.key('nosuch', 'm.lua::f'), store))
end)

test('axes: the writes axis counts the DEFINITION, so it is never a false zero',
    function ()
    -- reported on mantis: `✎ writes (0)` on $g_core_path, whose own source line
    -- is an assignment. The use edges skip the def-line mention on purpose (that
    -- is what makes `const` mean "never assigned AGAIN"), so the axis puts it
    -- back, marked. Sound because a var node only EXISTS when it was
    -- initialized: a bare `local plain` produces no node at all.
    reset({ mod('m.lua'), { id = 'm.lua::var:cfg@2', name = 'cfg', kind = 'var',
        file = 'm.lua', range = R(2), order = 2 } })
    local rows = axreg.rows(axreg.key('writes', 'm.lua::var:cfg@2'), store)
    eq(1, #rows, 'a var with no write EDGES still has its definition')
    ok(rows[1].def, 'and the row says which one it is')
    ok(rows[1].name:find('definition', 1, true), 'in words, on the row')
    eq(2, rows[1].line)
    eq(1, axreg.count('writes', 'm.lua::var:cfg@2', store))
end)

test('axes: writes counts WRITERS, not occurrences (rw is per edge)', function ()
    -- `rw` is the union over an edge's occurrence ranges, so a function that both
    -- reads and writes a var carries rw=3 on ALL of them: a row per range claimed
    -- four writes where a php lazy-init getter has one. The axis counts what the
    -- atlas counts (edges), and every range rides along for the hover.
    reset({ mod('m.lua'), fn('m.lua::get', 'get'),
        { id = 'm.lua::var:c@1', name = 'c', kind = 'var', file = 'm.lua',
          range = R(1), order = 1 } })
    store.var_usedby['m.lua::var:c@1'] = { { from = 'm.lua::get', rw = 3, gw = 3,
        at = { R(4), R(5), R(6) } } } -- reads AND writes, three occurrences
    local rows = axreg.rows(axreg.key('writes', 'm.lua::var:c@1'), store)
    eq(2, #rows, 'the definition and ONE writer, not one row per occurrence')
    eq('get', rows[2].name)
    ok(rows[2].guarded, 'a fully guarded write says so (the lazy-init shape)')
    eq(3, #rows[2].ranges, 'and keeps every occurrence for the hover')
end)

test('axes: a thin index makes the COUNT unavailable, never a zero', function ()
    -- a door showing "(0)" on a graph with no call edges is a fabricated none —
    -- the same defect the concern registry's two-halved empty exists to prevent,
    -- and it would be told by BOTH arms, so it has to be stopped in the registry
    reset({ mod('m.lua'), fn('m.lua::f', 'f') })
    local thin, real = false, store.is_index_only -- RESTORE it: the store owns
    store.is_index_only = function () return thin end -- this, other specs read it
    eq(0, axreg.count('callees', 'm.lua::f', store))
    thin = true
    local unavail, why = axreg.count('callees', 'm.lua::f', store), axreg.unavailable(store)
    store.is_index_only = real
    eq(nil, unavail, 'unavailable, not 0')
    ok(why and why:find('index%-only'), 'and it says why')
end)

test('axes: an empty inbound CONE on a registered fn says why, not nothing',
    function ()
    -- the cone walks CALL edges only, so a function kept alive by a registration
    -- (a dispatch table) has no callers and an empty reached_by while being
    -- perfectly live. "reached by (0)" there reads as dead; the axis names the
    -- other half of the alibi instead.
    reset({ mod('m.lua'), fn('m.lua::handler', 'handler') })
    store.reg_by['m.lua::handler'] = { { from = 'm.lua', at = {} } }
    local rows, e = axreg.rows(axreg.key('reached_by', 'm.lua::handler'), store)
    eq(0, #rows)
    local note = e.note(store, 'm.lua::handler')
    ok(note and note:find('registered by m.lua', 1, true), 'names the registrant: '
        .. tostring(note))
    ok(note:find('calls only', 1, true), 'and says what the cone walks')
    -- a fn with no registrants gets no special sentence (the generic empty note)
    reset({ mod('m.lua'), fn('m.lua::lonely', 'lonely') })
    eq(nil, e.note(store, 'm.lua::lonely'))
end)
