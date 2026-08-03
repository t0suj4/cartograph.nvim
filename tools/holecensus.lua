-- THE TEST-TEMPLATE HOLE CENSUS (CART-0258) — "could we generate a test for this
-- function, and which of the holes are OUR gap rather than the honest frontier?"
-- Measured BEFORE writing any emitter, in the tools/pathsat + tools/ifaceceil style.
--
--   nvim --headless -u NONE -l tools/holecensus.lua <corpus|path>
--        [--by kind|tier|rule|file] [--show N]
--   nvim --headless -u NONE -l tools/holecensus.lua --selftest
--
-- THE IDEA (user, 2026-08-03). Generate tests as a TEMPLATE WITH HOLES. Cartograph
-- never executes user code, so it cannot know an expected value — and rather than
-- guess one, the expected value is a HOLE. That is the never-draw invariant applied
-- to a new medium, not a workaround for it: the blocker becomes structural.
--
-- WHAT MAKES IT LEVERAGE: every hole is OWNED by an analysis, so each capability
-- narrows one (annotations → input types, nilflow → may-be-nil, argv+constfold →
-- concrete inputs, is_pure/effects → whether a fixture is needed at all). So HOLE
-- COUNT is one scalar that every analysis improvement moves, and unlike resolution%
-- it is USER-VISIBLE — a test you can run. It is also the executable counterpart to
-- neutrality.lua, which certifies a refactor changed nothing by hashing the df shape,
-- a PROXY; a characterization test is the real thing.
--
-- THIS TOOL COUNTS AND CLASSIFIES. IT EMITS NO TESTS. If the modal function carries
-- an unfillable fixture hole then the yield is poor, and that is worth a probe rather
-- than an emitter. HEADLINE = how many functions have ZERO frontier holes.
--
-- ── THE EDGE, NOT A LABEL ────────────────────────────────────────────────────
-- A hole is not LABELLED "our bug"; an EDGE is drawn from it to the evidence that
-- indicts us. A label asserts, an edge derives: you cannot draw one without pointing
-- at the other end, so the classification carries its provenance by construction, and
-- ABSENCE of the edge IS the honest frontier — rendered as an unlinked hole, never as
-- silence. Descending the edge is the DOOR of [[cartograph-explaining-a-finding]].
--
-- THE EDGE CARRIES A TIER, because the answer keys have UNEQUAL authority:
--   measured  an OBSERVED call-site literal (argv k='lit', constfold-upgraded
--             included). The code itself demonstrates a real input. Strongest here.
--   derived   OUR OWN analysis can supply it (e.g. the free name is a module-level
--             def in the same file, so loading the module supplies it).
--   claim     a DECLARED annotation. WEAKEST, deliberately: CART-0240 established
--             annotations are a CLAIM, not a fact, and shipped `annotation-mismatch`
--             precisely because docblocks disagree with the signatures beside them. An
--             annotation-indicted hole may mean the docblock is lying, not that we are
--             wrong. So "is this our gap" is ITSELF hedged, inheriting the evidence's
--             hedge — a flat boolean would be wrong in both directions.
--   (none)    FRONTIER. Nothing we have can fill it.
-- NOT IN V1: the lua-ls answer key (tools/conflicts.lua territory) and the observed
-- RUNTIME value (which only exists once an emitter runs a test — and would be the
-- strongest key of all, since a filled hole retroactively grades our inference).
--
-- HOME: the census carries its OWN hole/edge structure. `band.lua` is a READ-ONLY
-- topology view over the four gated EDGE_KINDS (ref/import/use/reg, enforced by
-- validate.lua) and there is no shipped writable derived-band container — "band =
-- lifecycle+trust unit" is a BANKED design. Homing this in a real band is follow-on
-- work and must NOT extend the project graph's closed schema.
--
-- ROTATION (--by): the point of edge-ness. Hold the holes and swap the axis — by KIND
-- (what is missing), by TIER (how well we could fill it), by RULE (which of OUR
-- analyzers owns the gap = the work-list), by FILE. Same structure, four readings.
--
-- SCOPE: Lua. Functions, not methods (a method's receiver is an input hole this
-- version does not model — see the report's skipped count).

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/[^/]*$')
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local annot = require 'cartograph.annot'
local argvm = require 'cartograph.argv'
local builtins = require 'cartograph.builtins'
local txn = require 'cartograph.txn'
local at = require 'cartograph.at'

-- ── the docblock above a def, as {params={name->type}, ret=bool} ─────────────
-- Mirrors lint.lua's annotation_findings walk (same reader, same adhesion rule).
local function doc_of(node, lines, pat, pats)
    if not (pat and lines) then return nil end
    local s0 = at.sl(node.range)
    local first = txn.attach_above(lines, s0, pats)
    if not first or first >= s0 then return nil end
    local tags = annot.read_block(lines, first, pat)
    if not tags or #tags == 0 then return nil end
    local out = { params = {}, ret = false }
    for _, t in ipairs(tags) do
        if t.kind == 'param' and t.name then out.params[t.name] = t.type or true
        elseif t.kind == 'return' then out.ret = true end
    end
    return out
end

-- ── one function's holes ────────────────────────────────────────────────────
-- hole = { kind, name, tier|nil, why, rule }
--   tier nil  = FRONTIER (no evidence edge)
--   rule      = which analysis OWNS filling it (the rotation axis that becomes a
--               work-list); recorded even when the hole is frontier, because "nobody
--               owns this" and "the owner failed" are different answers.
local function holes_of(node, ctx)
    -- expr.of, NOT flow.record, and the difference is load-bearing (see below):
    -- it materializes rows carrying `.expr` AND returns the spec-driven `bound` set
    -- (expr.bound_names over the language's declared binders), which is the only
    -- source that knows about LOOP VARIABLES.
    local eo = require('cartograph.expr').of(store, node.id)
    local fl = eo and eo.fl
    if not fl then return nil, 'no expression rows' end
    local params = fl.params
    -- TRI-STATE: nil means NOT ASKED, and treating it as {} is the bug CART-0125 was
    -- about. A fn we cannot get a param list for is UNMEASURABLE, not param-free.
    if params == nil then return nil, 'no param list (not asked)' end

    local H = {}
    local bound = {}
    for k in pairs(eo.bound or {}) do bound[k] = true end
    for _, p in ipairs(params) do bound[p] = true end
    for _, s in ipairs(fl.stmts or {}) do
        for _, d in ipairs(s.def or {}) do bound[d] = true end
    end

    -- 1. INPUT holes, one per parameter.
    -- A CONCRETE observed argument is k='lit' (a STRING literal — its `v` is always a
    -- string, per the constfold contract) OR k='scalar' (a number/boolean). Measured:
    -- `record("boot", 3)` yields lit then scalar. Checking only 'lit' silently
    -- under-counts every numeric input, and the distinction survives into an emitter,
    -- which must quote one and not the other. k='expr' (a table constructor) is NOT
    -- concrete — the value is a fresh allocation we cannot reproduce from the record.
    local CONCRETE = { lit = 'string', scalar = 'scalar' }
    local calls = store.calls_to and store.calls_to[node.id] or {}
    local litat, litk = {}, {}   -- param index → observed value, and its kind
    for _, c in ipairs(calls) do
        for i = 1, #params do
            if litat[i] == nil then
                local a = argvm.at(c, i)
                if a and CONCRETE[a.k] then litat[i], litk[i] = a.v or '', CONCRETE[a.k] end
            end
        end
    end
    for i, p in ipairs(params) do
        if litat[i] ~= nil then
            H[#H + 1] = { kind = 'input', name = p, tier = 'measured',
                rule = 'argv', why = ('a call site passes the %s %s'):format(litk[i],
                    tostring(litat[i]):sub(1, 24)) }
        elseif ctx.doc and ctx.doc.params[p] then
            H[#H + 1] = { kind = 'input', name = p, tier = 'claim', rule = 'annot',
                why = ('@param declares %s — a CLAIM, docblocks lie (CART-0240)')
                    :format(tostring(ctx.doc.params[p])) }
        else
            H[#H + 1] = { kind = 'input', name = p, rule = 'argv/annot/narrow',
                why = 'no observed literal, no declared type' }
        end
    end

    -- 2. ORACLE hole — the expected value. Absent when the function provably returns
    -- nothing: no `return` row at all, or every return row is a BARE `return` (an
    -- early exit). The bare test is TEXTUAL, deliberately conservative in the
    -- direction of claiming a hole (the flow row does not record arity).
    local retrows, valued = 0, false
    for _, s in ipairs(fl.stmts or {}) do
        if s.t == 'return_statement' then
            retrows = retrows + 1
            local l = ctx.lines and ctx.lines[(s.l or 0)]
            if not (l and (l:match('^%s*return%s*$') or l:match('^%s*return%s+end%s*$')
                or l:match('^%s*return%s*;%s*$'))) then valued = true end
        end
    end
    if retrows > 0 and valued then
        if ctx.doc and ctx.doc.ret then
            H[#H + 1] = { kind = 'oracle', name = '<return>', tier = 'claim',
                rule = 'annot', why = '@return constrains the shape, not the value' }
        else
            H[#H + 1] = { kind = 'oracle', name = '<return>', rule = 'execution',
                why = 'the value needs one RUN; no static tier can supply it' }
        end
    end

    -- 3. FIXTURE holes — free non-builtin VARIABLE reads. `derived` when a same-file
    -- definition carries the name, so loading the module supplies it.
    --
    -- READS COME FROM `expr.names(row)`, NOT from the flow row's `use`. This is the
    -- difference between a measurement and a fiction: `use` is the du-faithful
    -- IDENTIFIER-LEAF census, in which a dot/method SELECTOR counts as a read — so
    -- `n.file` contributes `file`, and `('%s'):format(x)` contributes `format`. Using
    -- it inflated this corpus's fixture holes to 28,313, and the top "free reads" were
    -- `_` (930), `match`, `format`, `concat` — loop variables and field names, not
    -- unmet dependencies. expr.lua labels the two functions explicitly: `reads` is
    -- "NOT the semantic variable set (a field selector isn't a var)" and `names` is
    -- "names semantically READ … for lints / eval env". This is the second.
    local expr = require 'cartograph.expr'
    local seen = {}
    for _, s in ipairs(fl.stmts or {}) do
        for _, u in ipairs(s.expr and expr.names(s.expr) or {}) do
            if not bound[u] and not seen[u] then
                seen[u] = true
                if not builtins.genuine('lua', u, bound) then
                    if ctx.samefile[u] then
                        H[#H + 1] = { kind = 'fixture', name = u, tier = 'derived',
                            rule = 'linker', why = 'a same-file definition carries this name' }
                    else
                        H[#H + 1] = { kind = 'fixture', name = u, rule = 'linker',
                            why = 'a free name with no definition we can see' }
                    end
                end
            end
        end
    end
    return H
end

-- ── sweep, streaming by file (the pathsat OOM lesson) ───────────────────────
local function sweep()
    local files, order = {}, {}
    for _, n in ipairs(store.data.nodes or {}) do
        if n.kind == 'function' and n.file and n.file:match('%.lua$') and n.range then
            if not files[n.file] then files[n.file] = {}; order[#order + 1] = n.file end
            local l = files[n.file]; l[#l + 1] = n
        end
    end
    local holes, fns = {}, {}
    local skipped = {}
    for _, rel in ipairs(order) do
        local nodes = files[rel]
        local lines = store.content(nodes[1])
        local pat = ts.annot_tag and ts.annot_tag(rel)
        local pats = ts.attach_pats and ts.attach_pats(rel)
        -- names DEFINED in this file, for the fixture tier
        local samefile = {}
        for _, x in ipairs(store.by_file and store.by_file[rel] or {}) do
            local nn = type(x) == 'table' and x or store.node(x)
            if nn and nn.name then samefile[nn.name] = true end
        end
        for _, n in ipairs(nodes) do
            local ctx = { lines = lines, samefile = samefile,
                doc = doc_of(n, lines, pat, pats) }
            local okh, H, why = pcall(holes_of, n, ctx)
            if not okh then
                skipped[#skipped + 1] = 'error'
            elseif not H then
                skipped[#skipped + 1] = why or '?'
            else
                local frontier, blocking = 0, 0
                for _, h in ipairs(H) do
                    h.fn, h.file = n.name or '?', rel
                    holes[#holes + 1] = h
                    if not h.tier then
                        frontier = frontier + 1
                        -- An ORACLE frontier hole is NOT blocking: it is the hole the
                        -- design expects a single RUN to fill, and no static tier can
                        -- ever supply it. Counting it against emittability made the
                        -- first headline (5.1% "zero-frontier") answer the wrong
                        -- question — every value-returning function has one by
                        -- construction. What BLOCKS emission is an input we cannot
                        -- choose or a fixture we cannot build.
                        if h.kind ~= 'oracle' then blocking = blocking + 1 end
                    end
                end
                fns[#fns + 1] = { fn = n.name or '?', file = rel,
                    n = #H, frontier = frontier, blocking = blocking }
            end
        end
        files[rel] = nil
    end
    return holes, fns, skipped
end

-- ── report ──────────────────────────────────────────────────────────────────
local function rotate(holes, axis)
    local key = ({ kind = 'kind', tier = 'tier', rule = 'rule', file = 'file' })[axis]
        or 'kind'
    local g = {}
    for _, h in ipairs(holes) do
        local k = h[key] or (key == 'tier' and 'FRONTIER' or '?')
        g[k] = g[k] or { n = 0, frontier = 0 }
        g[k].n = g[k].n + 1
        if not h.tier then g[k].frontier = g[k].frontier + 1 end
    end
    local ord = {}
    for k in pairs(g) do ord[#ord + 1] = k end
    table.sort(ord, function (a, b) return g[a].n > g[b].n end)
    return g, ord
end

local FIXTURE = table.concat({
    'local M = {}',
    'local LIMIT = 10',
    '',
    '--- Add two numbers.',
    '---@param a number',
    '---@param b number',
    '---@return number',
    'local function add(a, b)',
    '    return a + b',
    'end',
    '',
    -- fully templatable: params observed as literals below, returns nothing
    'local function record(name, count)',
    '    M.log = name',
    '    M.n = count',
    'end',
    '',
    -- a frontier oracle + a frontier input (no literal, no annotation)
    'local function murky(cb)',
    '    return cb()',
    'end',
    '',
    -- a fixture hole: reads LIMIT (same-file → derived) and UNKNOWN_G (frontier)
    'local function usesfree(x)',
    '    if x > LIMIT then return UNKNOWN_G end',
    '    return x',
    'end',
    '',
    'record("boot", 3)',
    'M.add, M.record, M.murky, M.usesfree = add, record, murky, usesfree',
    'return M',
}, '\n') .. '\n'

local function selftest()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/fx.lua', 'w')); fd:write(FIXTURE); fd:close()
    store.ingest(ts.extract(root))
    local holes = sweep()
    local by = {}
    for _, h in ipairs(holes) do
        by[h.fn] = by[h.fn] or {}
        by[h.fn][h.kind .. ':' .. h.name] = h.tier or 'FRONTIER'
    end
    local fails = {}
    local function chk(c, m) if not c then fails[#fails + 1] = m end end
    local function tier(fn, k) return by[fn] and by[fn][k] end

    -- `add` is annotated but never called with literals → params are CLAIM tier,
    -- and its @return makes the oracle a CLAIM too (shape, not value)
    chk(tier('add', 'input:a') == 'claim', 'add.a should be CLAIM (annotated): '
        .. tostring(tier('add', 'input:a')))
    chk(tier('add', 'oracle:<return>') == 'claim', 'add oracle should be CLAIM (@return)')
    -- `record` IS called with literals and returns nothing → NO oracle hole at all
    chk(tier('record', 'input:name') == 'measured', 'record.name should be MEASURED: '
        .. tostring(tier('record', 'input:name')))
    chk(tier('record', 'input:count') == 'measured', 'record.count should be MEASURED')
    chk(tier('record', 'oracle:<return>') == nil,
        'record must have NO oracle hole (returns nothing)')
    -- `murky` → both frontier
    chk(tier('murky', 'input:cb') == 'FRONTIER', 'murky.cb should be FRONTIER')
    chk(tier('murky', 'oracle:<return>') == 'FRONTIER', 'murky oracle should be FRONTIER')
    -- `usesfree` → LIMIT is same-file (derived), UNKNOWN_G is frontier
    chk(tier('usesfree', 'fixture:LIMIT') == 'derived',
        'LIMIT should be DERIVED (same-file def): ' .. tostring(tier('usesfree', 'fixture:LIMIT')))
    chk(tier('usesfree', 'fixture:UNKNOWN_G') == 'FRONTIER',
        'UNKNOWN_G should be FRONTIER: ' .. tostring(tier('usesfree', 'fixture:UNKNOWN_G')))
    -- a builtin must NOT become a fixture hole
    for _, h in ipairs(holes) do
        chk(not (h.kind == 'fixture' and builtins.lua[h.name]),
            'a genuine builtin became a fixture hole: ' .. tostring(h.name))
    end
    vim.fn.delete(root, 'rf')
    return fails
end

-- ── main ────────────────────────────────────────────────────────────────────
local target = arg[1]
local axis, show = 'kind', 10
for i = 1, #(arg or {}) do
    if arg[i] == '--by' then axis = arg[i + 1] or 'kind' end
    if arg[i] == '--show' then show = tonumber(arg[i + 1]) or 10 end
end

print('holecensus SELFTEST (a census that classifies nothing must not report)')
local fails = selftest()
for _, m in ipairs(fails) do print('  FAIL ' .. m) end
if #fails > 0 then
    print(('holecensus: SELFTEST FAILED (%d) — refusing to report'):format(#fails))
    os.exit(1)
end
print('  ok — measured/claim/derived/frontier each reached by a known case;'
    .. ' a void fn has no oracle hole; builtins are not fixtures')

if not target or target == '--selftest' then
    print('holecensus: selftest only (pass a corpus|path to sweep)')
    os.exit(0)
end

local reg = dofile(here .. '/corpora.lua')
local c = reg[target]
local root = c and vim.fn.expand(c.root) or vim.fn.expand(target)
if vim.fn.isdirectory(root) == 0 then
    print('holecensus: not a directory: ' .. root); os.exit(2)
end

print('')
print(('holecensus %s — %s'):format(target, root))
store.ingest(ts.extract(root))
local holes, fns, skipped = sweep()

local clean, emittable = 0, 0
local hist = {}
for _, f in ipairs(fns) do
    if f.frontier == 0 then clean = clean + 1 end
    if f.blocking == 0 then emittable = emittable + 1 end
    hist[f.blocking] = (hist[f.blocking] or 0) + 1
end
print(('  %d function(s) censused, %d skipped, %d hole(s)')
    :format(#fns, #skipped, #holes))
print(('  ★ EMITTABLE (no BLOCKING hole — every input choosable, every fixture'
    .. ' buildable; one RUN fills the oracle): %d / %d = %.1f%%')
    :format(emittable, #fns, #fns > 0 and 100 * emittable / #fns or 0))
print(('    of those, ZERO holes of any kind at all: %d'):format(clean))
local hk = {}
for k in pairs(hist) do hk[#hk + 1] = k end
table.sort(hk)
local buckets = {}
for _, k in ipairs(hk) do buckets[#buckets + 1] = ('%d:%d'):format(k, hist[k]) end
print(('    BLOCKING-holes-per-fn histogram: %s'):format(table.concat(buckets, ' ')))

print('')
print(('  ROTATED BY %s (n = holes, of which frontier):'):format(axis:upper()))
local g, ord = rotate(holes, axis)
for i = 1, math.min(#ord, show) do
    local k = ord[i]
    print(('    %-28s %6d   frontier %d (%.0f%%)'):format(k, g[k].n, g[k].frontier,
        g[k].n > 0 and 100 * g[k].frontier / g[k].n or 0))
end
if #ord > show then print(('    … %d more'):format(#ord - show)) end

-- the tier ladder, always printed: it is the whole point of the edge design
print('')
print('  EVIDENCE TIERS (the edge that indicts us; absence = honest frontier):')
local gt, ot = rotate(holes, 'tier')
for _, k in ipairs({ 'measured', 'derived', 'claim', 'FRONTIER' }) do
    if gt[k] then
        print(('    %-10s %6d'):format(k, gt[k].n))
    end
end
local _ = ot
