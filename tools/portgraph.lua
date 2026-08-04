-- THE PORT GRAPH (CART-0268, W1 of the anonymous-type partition CART-0267).
--
--   nvim --headless -u NONE -l tools/portgraph.lua <corpus|path> [--show N]
--        [--port 'callee#slot']   the "what accepts this?" query, with evidence counts
--   nvim --headless -u NONE -l tools/portgraph.lua --selftest
--
-- THE IDEA (user, [[cartograph-anonymous-types]]). For an unknown library function we
-- can never name the types — `FindComponent` returns some opaque handle. But if its
-- return flows into `RemoveFromParent`'s first argument, those two anonymous PORTS are
-- observably interchangeable. Sweep the corpus for such flows and you get COMPATIBILITY
-- CLASSES over a universe of things you cannot name: YOU DO NOT NEED THE NAME, YOU NEED
-- THE PARTITION. It buys completion ("what accepts this?"), a wrongness signal, stubs
-- for test generation (CART-0260), and navigation.
--
-- A PORT is (callee, slot) where slot is `ret`, `self` (a method receiver), or `aN`.
-- An EDGE is one OBSERVED flow between two ports, from real code doing it — so the
-- relation is EVIDENCE, never a declaration. Union-find over the edges gives the naive
-- partition. NO SOLVER: this is congruence closure, the third time this week something
-- looked like it needed one and did not (CART-0256, CART-0258, this).
--
-- ── WHAT W1 DELIVERS, AND WHAT IT DELIBERATELY DOES NOT ──────────────────────
-- W1 is the substrate plus a BASELINE. The naive partition is EXPECTED TO BE
-- DEGENERATE — one `function id(x) return x end` or a shared table everything passes
-- through and every class collapses into one blob. That is not a caveat to disclose, it
-- is CART-0269's (W2) work: a propagation RULE SET, whose ACCEPTANCE METRIC is the
-- class-size distribution printed below. So this tool exists partly to establish the
-- number W2 has to improve — a metric framed as a gate stops work, the same metric
-- framed as acceptance directs it.
--
-- THE ONE ACTUAL CAVEAT (a property, not a task): the partition is built from OBSERVED
-- flows, so it is a LOWER BOUND. Two ports that are compatible but never actually
-- connected in this corpus stay unlinked. Mirrors CART-0261: an observed input is a
-- lower bound on the domain, never the domain.
--
-- V1 APPROXIMATIONS, each a named W2 candidate rather than a hidden assumption:
--   * INTRA-PROCEDURAL only. A flow through a project function's parameter needs a
--     summary; that is federation's job ([[cartograph-consumer-federation]]).
--   * The local→producer map ignores ORDER and REACHING: a local rebound by a second
--     call is credited to whichever binding the row walk saw. Scope-correct reaching
--     (flow.reaching_cfg) is the fix and it belongs with W2's rules.
--   * A computed callee (`t[k]()`) has no dotted name and is SKIPPED, not guessed —
--     that is the genuinely dynamic frontier the partition cannot help with.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/[^/]*$')
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local expr = require 'cartograph.expr'
local annot = require 'cartograph.annot'
local txn = require 'cartograph.txn'
local at = require 'cartograph.at'

-- THE ANALYSIS NOW LIVES IN lua/cartograph/portflow.lua (W5, CART-0272) and this harness
-- READS IT. One implementation, so the probe's numbers and the verb's display cannot
-- diverge — the rule extractapply follows for its splice (CART-0125). What stays here is
-- the measurement the verb has no business carrying: the rule MATRIX, the sweeps, and the
-- baseline the rules had to beat.
local pf = require 'cartograph.portflow'
local port, collect, partition, together = pf.port, pf.collect, pf.partition, pf.together
local sinks_of, declarations, decl_of = pf.sinks_of, pf.declarations, pf.decl_of
local _ = sinks_of

-- ── selftest ────────────────────────────────────────────────────────────────
local FIXTURE = table.concat({
    'local M = {}',
    '',
    -- LOCAL-MEDIATED: FindComponent's return flows into RemoveFromParent's arg 1
    'local function chain(k)',
    '    local h = Engine.FindComponent(k)',
    '    Engine.RemoveFromParent(h)',
    'end',
    '',
    -- DIRECT NESTING: no local mediates it
    'local function nested(k)',
    '    Engine.Attach(Engine.FindComponent(k))',
    'end',
    '',
    -- METHOD RECEIVER: the handle flows into Destroy's `self` slot
    'local function meth(k)',
    '    local h = Engine.FindComponent(k)',
    '    h:Destroy()',
    'end',
    '',
    -- a SEPARATE opaque family that must NOT join the first one
    'local function other(k)',
    '    local s = Engine.OpenSocket(k)',
    '    Engine.CloseSocket(s)',
    'end',
    '',
    -- THE BLOB MAKER (CART-0269): both families flow into ipairs#a1, a universal sink,
    -- which fuses them. Baseline MUST show them fused; the rules MUST separate them
    -- while leaving each family's own class intact — the two-sided metric, gated.
    -- THREE receivers, not two, and deliberately: `bare` is DEGREE-GATED at MDEG=3, so a
    -- two-receiver port is NOT a sink (two values reaching one parameter can be a genuine
    -- shared supertype). With only two families they stay fused and the assertions below
    -- fail — correctly. The gate is part of the contract, so the fixture must clear it.
    'local function iterall(k)',
    '    local h = Engine.FindComponent(k)',
    '    local s = Engine.OpenSocket(k)',
    '    local q = Engine.OpenQueue(k)',
    '    for _, x in ipairs(h) do Engine.Touch(x) end',
    '    for _, y in ipairs(s) do Engine.Touch(y) end',
    '    for _, z in ipairs(q) do Engine.Touch(z) end',
    'end',
    '',
    'M.chain, M.nested, M.meth, M.other = chain, nested, meth, other',
    'M.iterall = iterall',
    'return M',
}, '\n') .. '\n'

local NO_RULES = {}
local ALL_RULES = { bare = true }

local function selftest()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/fx.lua', 'w')); fd:write(FIXTURE); fd:close()
    store.ingest(ts.extract(root))
    local col = collect(store)
    local base = partition(col, NO_RULES)
    local ruled = partition(col, ALL_RULES)
    local fails = {}
    local function chk(c, m) if not c then fails[#fails + 1] = m end end
    local FC = port('Engine.FindComponent', 'ret')
    local SOCK = port('Engine.OpenSocket', 'ret')
    local function same(g, a, b)
        return g.uf.p[a] and g.uf.p[b] and g.uf:find(a) == g.uf:find(b)
    end

    -- W1: the three observed flow shapes still link, under BOTH settings
    for label, g in pairs({ baseline = base, ruled = ruled }) do
        chk(same(g, FC, port('Engine.RemoveFromParent', 'a1')),
            label .. ': local-mediated flow must link FindComponent.ret ~ RemoveFromParent.a1')
        chk(same(g, FC, port('Engine.Attach', 'a1')),
            label .. ': DIRECT NESTING must link FindComponent.ret ~ Attach.a1')
        chk(same(g, FC, port('Destroy', 'self')),
            label .. ': a METHOD RECEIVER must be a port: FindComponent.ret ~ Destroy.self')
    end
    chk(col.is_ext(FC), 'Engine.FindComponent is EXTERNAL (absent from the corpus)')

    -- W2, SIDE ONE: the baseline MUST be degenerate here (both families fused through
    -- ipairs#a1) — if it is not, the fixture no longer exercises over-merging and every
    -- assertion below would pass vacuously.
    chk(same(base, FC, SOCK),
        'BASELINE must FUSE the two families through ipairs#a1 — else this fixture'
        .. ' does not test the rules at all')
    -- W2, SIDE TWO: the rules separate them…
    chk(not same(ruled, FC, SOCK),
        'the RULES must separate the two families (ipairs#a1 must stop transiting)')
    -- …WITHOUT breaking either family's own class. This is the half that a
    -- largest-class-share metric alone would never catch.
    chk(same(ruled, FC, port('Engine.RemoveFromParent', 'a1'))
        and same(ruled, FC, port('Engine.Attach', 'a1')),
        'the component family must SURVIVE the rules')
    chk(same(ruled, SOCK, port('Engine.CloseSocket', 'a1')),
        'the socket family must SURVIVE the rules')
    chk(ruled.sinks[port('ipairs', 'a1')] ~= nil,
        'ipairs#a1 must be marked a SINK (a bare global IS unqualified)')

    -- W3: MULTIPLICITY. Engine.Touch#a1 is fed from three separate ipairs loops, so its
    -- edges exist; and FindComponent.ret -> Destroy.self is seen ONCE. The counts must be
    -- recorded, because the count is what turns a claim into evidence.
    local w1 = col.w[FC .. '\1' .. port('Destroy', 'self')]
    chk(w1 == 1, 'a once-observed pair must have weight 1, got ' .. tostring(w1))
    -- FindComponent.ret is observed flowing into RemoveFromParent.a1 in `chain` and into
    -- Attach.a1 in `nested` — distinct partners, so DEGREE counts them separately while
    -- each edge keeps its own weight. Degree and weight are different axes.
    chk((col.pcount[FC] or 0) >= 3,
        'FindComponent.ret has >=3 DISTINCT partners, got ' .. tostring(col.pcount[FC]))

    -- W3: the NEIGHBOUR QUERY is the user-facing answer, and it is a ranked list with
    -- evidence rather than a type name.
    local nb = col.nbr[FC]
    chk(nb and #nb >= 3, 'the neighbour query returns FindComponent.ret\'s partners')
    if nb then
        local seenrfp = false
        for _, e in ipairs(nb) do
            if e[1] == port('Engine.RemoveFromParent', 'a1') then
                seenrfp = true
                chk(type(e[2]) == 'number' and e[2] >= 1, 'each neighbour carries a COUNT')
            end
        end
        chk(seenrfp, 'RemoveFromParent.a1 is among the neighbours')
    end

    -- W3: minw is an EVIDENCE THRESHOLD — at minw=2 the once-seen pairs stop linking.
    local strict = partition(col, { bare = true, minw = 2 })
    chk(not same(strict, FC, port('Destroy', 'self')),
        'at minw=2 a once-observed pair must NOT link')
    vim.fn.delete(root, 'rf')
    return fails
end

-- ── main ────────────────────────────────────────────────────────────────────
local target = arg[1]
local show, queryport = 8, nil
for i = 1, #(arg or {}) do
    if arg[i] == '--show' then show = tonumber(arg[i + 1]) or 8 end
    if arg[i] == '--port' then queryport = arg[i + 1] end
end

print('portgraph SELFTEST (a partition that merges everything must not report)')
local fails = selftest()
for _, m in ipairs(fails) do print('  FAIL ' .. m) end
if #fails > 0 then
    print(('portgraph: SELFTEST FAILED (%d) — refusing to report'):format(#fails))
    os.exit(1)
end
print('  ok — three flow shapes link under both settings; the BASELINE fuses two families\n    through ipairs#a1 and the RULES separate them WITHOUT breaking either (the two-sided\n    metric, gated); ipairs#a1 marked a sink; a degree-1 method receiver survives')

if not target or target == '--selftest' then
    print('portgraph: selftest only (pass a corpus|path to sweep)')
    os.exit(0)
end

local reg = dofile(here .. '/corpora.lua')
local c = reg[target]
local root = c and vim.fn.expand(c.root) or vim.fn.expand(target)
if vim.fn.isdirectory(root) == 0 then
    print('portgraph: not a directory: ' .. root); os.exit(2)
end

print('')
print(('portgraph %s — %s'):format(target, root))
store.ingest(ts.extract(root))
local col = collect(store)

local ext, tot = 0, 0
for p in pairs(col.pcount) do
    tot = tot + 1
    if col.is_ext(p) then ext = ext + 1 end
end
print(('  %d lua fn(s) walked · %d PORT(s) (%d external, %.0f%%) · %d observed EDGE(s)')
    :format(col.nfn, tot, ext, tot > 0 and 100 * ext / tot or 0, #col.edges))

-- ── THE RULE MATRIX (CART-0269) ─────────────────────────────────────────────
-- One row per rule combination, because "neither rule alone suffices" is itself a
-- finding and a single hardcoded setting would hide it. `largest%` is side ONE of the
-- acceptance metric; `kept` is side TWO — the real classes that must survive, hand-read
-- in CART-0268. A row that wins on largest% while losing `kept` has traded one worthless
-- answer for another.
local FIXTURES = {
    { name = 'nvim window handle', ports = {
        'vim.api.nvim_get_current_win#ret', 'vim.api.nvim_win_set_height#a1',
        'vim.api.nvim_set_current_win#a1' } },
    { name = 'function id', ports = { 'fn_id#ret', 'optimize.cse#a2' } },
    { name = 'desynced location', ports = {
        'heart.GetLocationXY#ret', 'RevealArea#a1', 'SpawnExplorable#a1' } },
}
local ROWS = {
    { label = 'baseline (W1)',   opts = {} },
    { label = 'bare (deg>=3)',   opts = { bare = true } },
    { label = 'bare + deg>=12 ★', opts = { bare = true, degree = 12 } },
    { label = 'bare + deg>=8',   opts = { bare = true, degree = 8 } },
}
print('')
print('  RULE MATRIX — largest% is side ONE of the metric, kept-classes side TWO:')
print(('    %-24s %6s %7s %9s %8s  %s'):format('rules', 'sinks', 'classes', 'largest', 'largest%', 'kept'))
for _, r in ipairs(ROWS) do
    local part = partition(col, r.opts)
    local big = part.classes[1] and #part.classes[1] or 0
    local kept, avail = 0, 0
    for _, f in ipairs(FIXTURES) do
        -- only score a fixture whose ports exist in THIS corpus
        local present = false
        for _, pt in ipairs(f.ports) do if col.pcount[pt] then present = true end end
        if present then
            avail = avail + 1
            if together(part, f.ports) then kept = kept + 1 end
        end
    end
    print(('    %-24s %6d %7d %9d %7.1f%%  %d/%d'):format(r.label, part.nsink,
        #part.classes, big, part.ports > 0 and 100 * big / part.ports or 0, kept, avail))
end
print('    (kept = the hand-read real classes still in ONE class; only those whose ports')
print('     exist in this corpus are scored, so `avail` differs per corpus)')

-- ── DEGREE SENSITIVITY, on top of builtin+method ────────────────────────────
-- The degree rule is a CALIBRATION, so the curve is printed instead of a magic number
-- being buried in the code. Read the knee; do not read a single row.
-- ── W3: THE EVIDENCE AXIS ───────────────────────────────────────────────────
-- Weight is a DIFFERENT axis from degree, and the prediction recorded in CART-0270 before
-- building was that it would barely move largest%: the blob is many DISTINCT edges into one
-- sink (fan-in), each observed once or twice, so filtering per-edge weight removes
-- scattered pairs rather than the fan-in. These rows test that rather than assume it.
print('')
print('  EVIDENCE (W3) — edge weight = how many SITES observed that exact pair:')
local whist, wtot, wmax = {}, 0, 0
for _, n in pairs(col.w) do
    whist[n] = (whist[n] or 0) + 1
    wtot = wtot + 1
    if n > wmax then wmax = n end
end
local wk = {}
for k in pairs(whist) do wk[#wk + 1] = k end
table.sort(wk)
local wb = {}
for _, k in ipairs(wk) do wb[#wb + 1] = ('%d:%d'):format(k, whist[k]) end
print(('    weight:edges  %s   (max %d)'):format(table.concat(wb, ' '), wmax))
for _, mw in ipairs({ 1, 2, 3 }) do
    local part = partition(col, { bare = true, degree = 12, minw = mw })
    local big = part.classes[1] and #part.classes[1] or 0
    local kept, avail = 0, 0
    for _, f in ipairs(FIXTURES) do
        local present = false
        for _, pt in ipairs(f.ports) do if col.pcount[pt] then present = true end end
        if present then
            avail = avail + 1
            if together(part, f.ports) then kept = kept + 1 end
        end
    end
    print(('    minw >= %d   classes %-5d largest %-5d (%.1f%%)  kept %d/%d')
        :format(mw, #part.classes, big,
            part.ports > 0 and 100 * big / part.ports or 0, kept, avail))
end
print('    (a class is a QUERY at a stated threshold, never a stored partition)')

print('')
print('  DEGREE SWEEP (on top of `bare`) — a calibration, shown not hidden:')
for _, d in ipairs({ 8, 12, 16, 20, 30, 50 }) do
    local part = partition(col, { bare = true, degree = d })
    local big = part.classes[1] and #part.classes[1] or 0
    local kept, avail = 0, 0
    for _, f in ipairs(FIXTURES) do
        local present = false
        for _, pt in ipairs(f.ports) do if col.pcount[pt] then present = true end end
        if present then
            avail = avail + 1
            if together(part, f.ports) then kept = kept + 1 end
        end
    end
    print(('    degree >= %-3d  sinks %-5d classes %-5d largest %-5d (%.1f%%)  kept %d/%d')
        :format(d, part.nsink, #part.classes, big,
            part.ports > 0 and 100 * big / part.ports or 0, kept, avail))
end

-- ── the chosen operating point, in detail ───────────────────────────────────
-- THE CHOSEN OPERATING POINT, picked from the sweep rather than assumed: deg>=12 is the
-- most aggressive threshold at which BOTH corpora keep every real class (self drops to
-- 21.6% from 69.7%, desynced to 15.2% from 79.8%; deg>=8 goes further on desynced but
-- breaks a real class on self). A calibration, so the curve above stays printed.
local best = partition(col, { bare = true, degree = 12 })
print('')
print('  TOP PORTS BY DEGREE (the sinks the rules caught are marked):')
local pd = {}
for p, n in pairs(col.pcount) do pd[#pd + 1] = { p = p, n = n } end
table.sort(pd, function (a, b) return a.n > b.n end)
for i = 1, math.min(#pd, 8) do
    print(('    %-42s degree %-4d %s'):format(pd[i].p, pd[i].n,
        best.sinks[pd[i].p] and ('SINK (' .. best.sinks[pd[i].p] .. ')') or ''))
end

print('')
print('  LARGEST CLASSES at the operating point bare+deg>=12:')
for i = 1, math.min(#best.classes, show) do
    local m = best.classes[i]
    table.sort(m, function (a, b) return (col.pcount[a] or 0) > (col.pcount[b] or 0) end)
    local shown = {}
    for j = 1, math.min(#m, 6) do shown[#shown + 1] = m[j] end
    print(('    [%d ports] %s%s'):format(#m, table.concat(shown, '  '),
        #m > 6 and ('  … +' .. (#m - 6)) or ''))
end


-- ── W4: AMPLIFICATION AND CONFLICTS (CART-0271) ─────────────────────────────
-- AMPLIFICATION answers "how many ports does ONE declaration name?" — the profile lever,
-- quantified. CONFLICTS answer "does the partition agree with the declarations?" — a
-- self-check that needs no hand-reading, since two different declared types inside one
-- class mean we over-merged or the docblocks disagree.
--
-- PREDICTION recorded in CART-0271 before running: conflicts CONCENTRATE in the large
-- classes (the residual blob) and are RARE in small ones. If that holds,
-- conflicts-per-class is a proxy for partition quality; if they are spread uniformly, the
-- partition is worse than class size suggests and W2 is not done.
local byname, decl = declarations(store)
local ndecl = 0
for _ in pairs(decl) do ndecl = ndecl + 1 end

local resolved, declared = 0, 0
local pdecl = {}
for pt in pairs(col.pcount) do
    local d, ok = decl_of(byname, decl, pt)
    if ok then resolved = resolved + 1 end
    if d then declared = declared + 1; pdecl[pt] = d end
end
print('')
print(('  W4 DECLARATIONS — %d annotated fn(s); %d/%d ports resolved to a node (%.0f%%),'
    .. ' %d carry a declared type'):format(ndecl, resolved, tot,
    tot > 0 and 100 * resolved / tot or 0, declared))

local named, conflict, ampl, singles = 0, 0, 0, 0
local conflicts, bysize = {}, { big = 0, bigc = 0, small = 0, smallc = 0 }
for _, m in ipairs(best.classes) do
    local kinds, first = {}, nil
    local n = 0
    for _, pt in ipairs(m) do
        local d = pdecl[pt]
        if d then
            if kinds[d] == nil then kinds[d] = 0; n = n + 1; first = first or d end
            kinds[d] = kinds[d] + 1
        end
    end
    local isbig = #m >= 10
    if isbig then bysize.big = bysize.big + 1 else bysize.small = bysize.small + 1 end
    if n == 1 then
        named = named + 1
        ampl = ampl + #m
        if #m == 1 then singles = singles + 1 end
    elseif n > 1 then
        conflict = conflict + 1
        if isbig then bysize.bigc = bysize.bigc + 1 else bysize.smallc = bysize.smallc + 1 end
        local ks = {}
        for k, c in pairs(kinds) do ks[#ks + 1] = ('%s x%d'):format(k, c) end
        table.sort(ks)
        conflicts[#conflicts + 1] = { size = #m, kinds = ks, sample = m[1] }
    end
end
print(('    classes NAMED by >=1 declaration: %d — they cover %d ports, so one declaration'
    .. ' names %.1f ports on average (%d of them name only themselves)')
    :format(named, ampl, named > 0 and ampl / named or 0, singles))
print(('    classes with CONFLICTING declarations: %d'):format(conflict))
print(('    …by class size: big (>=10 ports) %d/%d conflict (%.0f%%) ·'
    .. ' small %d/%d (%.0f%%)'):format(bysize.bigc, bysize.big,
    bysize.big > 0 and 100 * bysize.bigc / bysize.big or 0,
    bysize.smallc, bysize.small,
    bysize.small > 0 and 100 * bysize.smallc / bysize.small or 0))
if #conflicts > 0 then
    table.sort(conflicts, function (a, b) return a.size > b.size end)
    print('    CONFLICTS (a declaration is a CLAIM — never resolved by majority):')
    for i = 1, math.min(#conflicts, 6) do
        local c = conflicts[i]
        print(('      [%d ports] %s   e.g. %s'):format(c.size,
            table.concat(c.kinds, ' | '):sub(1, 90), c.sample))
    end
end

-- ── W3: THE PORT QUERY ──────────────────────────────────────────────────────
-- The user-facing capability, in its honest form. "What accepts this?" is answered with a
-- RANKED LIST CARRYING EVIDENCE — "observed interchangeable at N sites" — never with a type
-- name we do not have. This is W5's input.
if queryport then
    print('')
    local nb = col.nbr[queryport]
    if not nb then
        print(('  PORT %s — no observed flows (unlinked: the honest frontier)')
            :format(queryport))
    else
        local cls = best.uf.p[queryport] and best.uf:find(queryport)
        local size = 0
        if cls then
            for _, m in ipairs(best.classes) do
                if best.uf:find(m[1]) == cls then size = #m break end
            end
        end
        print(('  PORT %s — %d observed partner(s); class of %d at bare+deg>=12%s')
            :format(queryport, #nb, size,
                best.sinks[queryport] and (' — SINK (' .. best.sinks[queryport] .. ')') or ''))
        for i = 1, math.min(#nb, 12) do
            print(('    %-46s observed at %d site(s)'):format(nb[i][1], nb[i][2]))
        end
        if #nb > 12 then print(('    … %d more'):format(#nb - 12)) end
    end
end
