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
local expr = require 'cartograph.expr'
local txn = require 'cartograph.txn'
local at = require 'cartograph.at'
local pm = require 'cartograph.spec.profile'
local holes = require 'cartograph.holes'
local ch = require 'cartograph.characterize'
local synth = require 'cartograph.synth'
-- ALIASED BEFORE THE SHADOW: the report section rebinds `holes` to the sweep's ROW LIST
-- (`local holes, fns, skipped = sweep()`), so the module is out of reach down there.
local blocking_of = holes.blocking
-- THE BASE RUNTIME'S SIGNATURES (CART-0266), loaded once. nil when no artifact
-- ships for the language, and the report SAYS so — a stub gap and a missing
-- signature SOURCE must not render the same way.
local stdprof = pm.load(pm.base_for("lua"))

-- THE HOLE COMPUTATION LIVES IN cartograph.holes (extracted CART-0262), so this
-- probe and the EMITTER cannot disagree about what a hole is — the portflow.lua
-- posture: one module, two surfaces. What stays here is the harness: the streaming
-- sweep, the rotations, and the numbers.

-- ── sweep, streaming by file (the pathsat OOM lesson) ───────────────────────
local function sweep()
    local files, order = {}, {}
    for _, n in ipairs(store.data.nodes or {}) do
        if n.kind == 'function' and n.file and n.file:match('%.lua$') and n.range then
            if not files[n.file] then files[n.file] = {}; order[#order + 1] = n.file end
            local l = files[n.file]; l[#l + 1] = n
        end
    end
    local rows, fns = {}, {}
    local skipped = {}
    for _, rel in ipairs(order) do
        local nodes = files[rel]
        local lines = store.content(nodes[1])
        local pat = ts.annot_tag and ts.annot_tag(rel)
        local pats = ts.attach_pats and ts.attach_pats(rel)
        for _, n in ipairs(nodes) do
            -- THE CENSUS CONSUMES THE EMITTER'S PLAN (CART-0284). It used to call holes.of
            -- directly, which was fine until the EMITTER learned four more hole kinds — reach,
            -- load, env, inspect — and the census kept counting the old four. Its headline
            -- silently stopped describing what an emittable function needs: 18.0% here against
            -- the emitter's 3.7% on the same corpus.
            --
            -- `holes.of` was extracted so the two could not disagree, and they diverged anyway,
            -- because ONE SHARED FUNCTION IS NOT PARITY IF NEW WORK GOES AROUND IT. So the fix
            -- is not another shared helper to maintain — it is to make the census a CONSUMER of
            -- the single producer. characterize.plan calls holes.of and adds what only it can
            -- see; the census now measures exactly the hole set the emitter faces, and a fifth
            -- hole kind cannot desynchronise them because there is nothing left to synchronise.
            local okh, plan, why = pcall(ch.plan, store, n.id)
            local H = okh and plan and plan.holes or nil
            if not okh then
                skipped[#skipped + 1] = 'error'
            elseif not H then
                skipped[#skipped + 1] = tostring(plan == nil and why or 'no plan')
            else
                local frontier, blocking, novalue, inblocking = 0, 0, 0, 0
                for _, h in ipairs(H) do
                    h.fn, h.file = n.name or '?', rel
                    rows[#rows + 1] = h
                    -- RUNNABLE is a different question from EMITTABLE and needs its own count:
                    -- a TIER is not a VALUE, so an `@param number` unblocks a hole while giving
                    -- us nothing to call the function with. Two questions, two numbers, and they
                    -- must never share a word again.
                    if h.kind ~= 'oracle' and h.kind ~= 'effects'
                        and not (h.value or h.satisfied_by) then novalue = novalue + 1 end
                    if not h.tier then
                        frontier = frontier + 1
                        -- What BLOCKS emission is narrower than "frontier":
                        --  · ORACLE      never blocks — it is the hole a single RUN
                        --    fills, and no static tier can ever supply it. Counting it
                        --    made the first headline (5.1%) answer the wrong question:
                        --    every value-returning fn has one by construction.
                        --  · DEPENDENCY  blocks only when `hard` — an absent require is
                        --    an INJECTION POINT, so a stub always exists; but if the fn
                        --    writes module state or mutates an argument, injection
                        --    cannot isolate it and the dependency is a real wall.
                        --  · INPUT / FIXTURE always block: we cannot choose the RIGHT
                        --    value or build the world. Note "right" — an input hole is a
                        --    GENERALITY limit, not a runnability one, which is what the
                        --    third headline below measures (CART-0290).
                        if holes.blocking(h) then
                            blocking = blocking + 1
                            if h.kind == 'input' then inblocking = inblocking + 1 end
                        end
                    end
                end
                fns[#fns + 1] = { fn = n.name or '?', file = rel, id = n.id,
                    n = #H, frontier = frontier, blocking = blocking, novalue = novalue,
                    inblocking = inblocking }
            end
        end
        files[rel] = nil
    end
    return rows, fns, skipped
end

-- ── report ──────────────────────────────────────────────────────────────────
local function rotate(holes, axis)
    -- `dep` = DEPENDENCY holes only, grouped by the absent callee's NAME. This is the
    -- PROFILE WORK-LIST: "we do not know how to stub it" is not the honest frontier, it
    -- is a statement about our profile COVERAGE — the callee has a real documented
    -- signature somewhere (CART-0029's adapters: factorio runtime-api.json, RBS,
    -- typeshed). FREQUENCY is the evidence: a name called hundreds of times is not
    -- exotic, it is a core API we are missing.
    -- AND IT IS A WORK-LIST, SO IT MUST NOT LIST FINISHED WORK (CART-0266). A builtin
    -- is legitimately "outside the corpus" and so has always appeared here — ipairs 258
    -- on desynced — non-frontier and therefore harmless to the verdict, but pure noise
    -- in the one view whose whole purpose is "what should we go and model next". A hole
    -- that already has a signature is not a gap in our coverage; the ROSTER of stdlib
    -- signatures is printed separately, where it belongs.
    local depmode = axis == 'dep'
    local key = ({ kind = 'kind', tier = 'tier', rule = 'rule', file = 'file',
        dep = 'name' })[axis] or 'kind'
    local g = {}
    for _, h in ipairs(holes) do
        if depmode and h.rule == 'stdlib' then goto skip end
        if not depmode or h.kind == 'dependency' then
        local k = h[key] or (key == 'tier' and 'FRONTIER' or '?')
        g[k] = g[k] or { n = 0, frontier = 0 }
        g[k].n = g[k].n + 1
        if not h.tier then g[k].frontier = g[k].frontier + 1 end
        end
        ::skip::
    end
    local ord = {}
    for k in pairs(g) do ord[#ord + 1] = k end
    table.sort(ord, function (a, b) return g[a].n > g[b].n end)
    return g, ord
end

-- THE FIXTURE'S FUNCTIONS ARE EXPORTED, and that is not cosmetic (CART-0284). They were all
-- `local function`, so once the census consumes the emitter's plan every one of them carries a
-- REACH hole — nothing outside the file can call a file-local function, so no spec can either —
-- and that hole would mask every assertion below it about inputs, oracles and dependencies. Worth
-- saying plainly: while the census computed its own hole set it had never measured a function a
-- spec could actually CALL, which is a large part of why its headline read so much higher than the
-- emitter's.
local FIXTURE = table.concat({
    'local M = {}',
    'local LIMIT = 10',
    '',
    '--- Add two numbers.',
    '---@param a number',
    '---@param b number',
    '---@return number',
    'function M.add(a, b)',
    '    return a + b',
    'end',
    '',
    -- fully templatable: params observed as literals below, returns nothing
    'function M.record(name, count)',
    '    M.log = name',
    '    M.n = count',
    'end',
    '',
    -- a frontier oracle + a frontier input (no literal, no annotation)
    'function M.murky(cb)',
    '    return cb()',
    'end',
    '',
    -- a fixture hole: reads LIMIT (same-file → derived) and UNKNOWN_G (frontier)
    'function M.usesfree(x)',
    '    if x > LIMIT then return UNKNOWN_G end',
    '    return x',
    'end',
    '',
    -- INJECTION: calls an absent dependency and is otherwise clean → the dependency
    -- hole must be SOFT (non-blocking), so the fn stays emittable
    'function M.injects(v)',
    '    return AbsentLib.transform(v)',
    'end',
    '',
    -- HARD: same absent call, but it also MUTATES ITS ARGUMENT, so injection cannot
    -- isolate it and the dependency hole must BLOCK
    'function M.mutates(rec)',
    '    rec.seen = AbsentLib.stamp()',
    '    return rec',
    'end',
    '',
    'record("boot", 3)',
    'injects(1)',
    'M.add, M.record, M.murky, M.usesfree = add, record, murky, usesfree',
    'M.injects, M.mutates = injects, mutates',
    'return M',
}, '\n') .. '\n'

local function selftest()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/fx.lua', 'w')); fd:write(FIXTURE); fd:close()
    store.ingest(ts.extract(root))
    local holes, fns = sweep()
    local by, hard, blk = {}, {}, {}
    for _, h in ipairs(holes) do
        by[h.fn] = by[h.fn] or {}
        by[h.fn][h.kind .. ':' .. h.name] = h.tier or 'FRONTIER'
        if h.kind == 'dependency' then hard[h.fn] = h.hard and true or false end
    end
    for _, f in ipairs(fns) do blk[f.fn] = f.blocking end
    local fails = {}
    local function chk(c, m) if not c then fails[#fails + 1] = m end end
    -- the fixture EXPORTS its functions (see the note on FIXTURE), so a node's name is
    -- `M.add`, not `add`. One prefix here rather than the same edit on twenty lookups.
    local function tier(fn, k) return by['M.' .. fn] and by['M.' .. fn][k] end
    local function blkof(fn) return blk['M.' .. fn] end
    local function hardof(fn) return hard['M.' .. fn] end

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
    -- INJECTION: an absent dependency in an otherwise-clean fn is a SOFT hole, so the
    -- function stays EMITTABLE — this is the whole point of the injection frame.
    chk(hardof('injects') == false, 'injects: the absent dep must be SOFT (injectable)')
    chk(blkof('injects') == 0,
        'injects must be EMITTABLE despite the absent dependency, got blocking='
        .. tostring(blkof('injects')))
    -- …but the same absent call in a fn that MUTATES ITS ARGUMENT is HARD and blocks:
    -- injection cannot isolate a function that writes through its own parameter.
    chk(hardof('mutates') == true, 'mutates: the absent dep must be HARD (arg mutation)')
    chk((blkof('mutates') or 0) > 0, 'mutates must NOT be emittable, got blocking='
        .. tostring(blkof('mutates')))
    vim.fn.delete(root, 'rf')
    return fails
end

-- ── main ────────────────────────────────────────────────────────────────────
local target = arg[1]
local axis, show = 'kind', 10
for i = 1, #(arg or {}) do
    if arg[i] == '--by' then axis = arg[i + 1] or 'kind' end
    if arg[i] == '--show' then show = tonumber(arg[i + 1]) or 10 end
    -- THE A/B FOR CART-0266, so the stdlib-signature delta is REPRODUCIBLE rather
    -- than a number someone remembered from a session. Drops the signature source and
    -- nothing else, which is exactly the before-state.
    if arg[i] == '--no-stdlib' then stdprof = nil end
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

local clean, emittable, runnable = 0, 0, 0
local hist = {}
for _, f in ipairs(fns) do
    if f.frontier == 0 then clean = clean + 1 end
    if f.blocking == 0 then emittable = emittable + 1 end
    if (f.novalue or 0) == 0 then runnable = runnable + 1 end
    hist[f.blocking] = (hist[f.blocking] or 0) + 1
end
print(('  %d function(s) censused, %d skipped, %d hole(s)')
    :format(#fns, #skipped, #holes))
-- TWO NUMBERS, NEVER ONE WORD (CART-0284). EMITTABLE asks "does anything at all speak to every
-- hole"; RUNNABLE asks "can we actually call it". A tier is not a value, and the gap between them
-- was invisible while one word carried both.
print(('  ★ EMITTABLE (no BLOCKING hole — something speaks to every hole): %d / %d = %.1f%%')
    :format(emittable, #fns, #fns > 0 and 100 * emittable / #fns or 0))
print(('  ★ RUNNABLE  (every hole carries a VALUE — we could actually call it): %d / %d = %.1f%%')
    :format(runnable, #fns, #fns > 0 and 100 * runnable / #fns or 0))
-- AND A THIRD, KEPT SEPARATE (CART-0290, user: "there should be very few functions we cannot run
-- with filled holes"). The two above count REAL EVIDENCE. This one counts functions whose only
-- walls are input holes we could SYNTHESIZE from what the body requires of each parameter — our
-- own values, so they are reported on their own line and never added into EMITTABLE. Folding a
-- guess into an evidence number is how a survey lies by confidence, and the largest hole
-- population in the corpus is the worst place to start doing it.
local synthable, synthrefused = 0, 0
for _, f in ipairs(fns) do
    if f.blocking > 0 and f.blocking == (f.inblocking or 0) and f.id then
        local okp, plan = pcall(ch.plan, store, f.id)
        if okp and plan then
            local nf, ref = synth.fill(store, plan)
            if nf then
                local left = 0
                for _, h in ipairs(plan.holes) do
                    if not h.tier and blocking_of(h) and not h.value then left = left + 1 end
                end
                if left == 0 then synthable = synthable + 1 end
                if type(ref) == 'table' and #ref > 0 then synthrefused = synthrefused + 1 end
            end
        end
    end
end
print(('  ★ + RUNNABLE UNDER SYNTHESIS (inputs we would CHOOSE, tier derived|claim): %d'
    .. ' / %d = %.1f%%  → together %.1f%%'):format(synthable, #fns,
    #fns > 0 and 100 * synthable / #fns or 0,
    #fns > 0 and 100 * (emittable + synthable) / #fns or 0))
print(('      a synthesized input exercises ONE path and the path is OUR choice, so this is'
    .. ' its own number%s'):format(synthrefused > 0
    and (('; %d fn(s) REFUSED — the body uses a parameter as two types'):format(synthrefused))
    or ''))
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

-- ── THE STDLIB SIGNATURE SPLIT (CART-0266) ──────────────────────────────────
-- Printed SEPARATELY from the count, because "5020 stubs now have a signature" would
-- overstate it: a member-name match with an UNVERIFIED RECEIVER (`s:match` →
-- string#match, the only stdlib owner of that name) is a hedge, and a value of some
-- other type carrying a same-named method would be mis-signed. The sound rungs name
-- their own namespace (`table.concat`) or are free functions (`tostring`).
-- A SET is reported where the name has several owners — `close` is file's AND io's, so
-- the honest answer is both and the receiver is what we do not have.
local n_sound, n_hedged, n_set, n_absent_mem = 0, 0, 0, 0
for _, h in ipairs(holes) do
    if h.rule == 'stdlib' then
        if h.hedged then n_hedged = n_hedged + 1 else n_sound = n_sound + 1 end
    elseif h.kind == 'dependency' and h.why then
        if h.why:find('a SET,', 1, true) then n_set = n_set + 1
        elseif h.why:find('does not hold this member', 1, true) then
            n_absent_mem = n_absent_mem + 1
        end
    end
end
if not stdprof then
    print('')
    print('  STDLIB SIGNATURES: none — no base-runtime profile for lua (--no-stdlib, or'
        .. ' no artifact ships). Every stub shape below is the effect vocabulary at best.')
elseif n_sound + n_hedged + n_set > 0 then
    print('')
    print(('  STDLIB SIGNATURES (%s, tier=claim — %s):'):format(stdprof.runtime,
        stdprof.sig_kind or 'no sig_kind'))
    print(('    %6d SOUND   the call names its own namespace, or a free function'):format(n_sound))
    print(('    %6d HEDGED  unique member name, RECEIVER UNVERIFIED — a guess that'
        .. ' happens to have exactly one candidate'):format(n_hedged))
    print(('    %6d SET     several stdlib owners declare the name; the receiver'
        .. ' decides and we do not have it'):format(n_set))
    if n_absent_mem > 0 then
        print(('    %6d ABSENT  the namespace IS the stdlib and lacks the member — an'
            .. ' absence, stronger than an unknown'):format(n_absent_mem))
    end
end
