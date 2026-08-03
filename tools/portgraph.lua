-- THE PORT GRAPH (CART-0268, W1 of the anonymous-type partition CART-0267).
--
--   nvim --headless -u NONE -l tools/portgraph.lua <corpus|path> [--show N]
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

-- ── union-find over port keys ───────────────────────────────────────────────
local UF = {}
UF.__index = UF
local function uf() return setmetatable({ p = {}, n = 0 }, UF) end
function UF:add(k)
    if self.p[k] == nil then self.p[k] = k; self.n = self.n + 1 end
    return k
end
function UF:find(k)
    local p = self.p
    while p[k] ~= k do p[k] = p[p[k]]; k = p[k] end
    return k
end
function UF:union(a, b)
    local ra, rb = self:find(self:add(a)), self:find(self:add(b))
    if ra ~= rb then self.p[ra] = rb end
end

local function port(name, slot) return name .. '#' .. slot end

-- ── one function's observed flows ───────────────────────────────────────────
-- Everything comes off the expr IR: a `call` node is { k='call', f=<callee expr>,
-- a={args}, method=bool }, and expr.dotted turns a name/field chain into the qualified
-- callee name (nil for a computed callee, which we skip rather than guess).
local function flows_of(node, emit)
    local eo = expr.of(store, node.id)
    local fl = eo and eo.fl
    if not fl then return end

    -- local name → the callee whose RETURN was assigned to it
    local prod = {}
    for _, s in ipairs(fl.stmts or {}) do
        local rhs = s.expr and s.expr.rhs
        local first = rhs and rhs[1]
        if first and first.k == 'call' and s.def then
            local cn = expr.dotted(first.f)
            if cn then for _, d in ipairs(s.def) do prod[d] = cn end end
        end
    end

    -- every call node in the body, and where each of its arguments came from
    local function visit(e)
        if type(e) ~= 'table' then return end
        if e.k == 'call' then
            -- A METHOD call keys on the METHOD SEGMENT alone, not on expr.dotted, which
            -- would return `h.Destroy` — the receiver VARIABLE's name is not part of the
            -- callee's identity, and not knowing the receiver's type is the entire point.
            -- NAMED W2 CANDIDATE (CART-0269): bare-method-name ports are a KNOWN
            -- over-merge source — every `:destroy()` in a corpus collapses into one port
            -- regardless of receiver class. A rule must keep them apart unless the
            -- receiver classes already unify.
            local cname = e.method and e.f and e.f.n or expr.dotted(e.f)
            if cname then
                -- a METHOD receiver is a port too: `h:Destroy()` says whatever `h`
                -- holds flows into Destroy's `self` slot.
                if e.method and e.f.b then
                    local rn = (e.f.b.k == 'name') and e.f.b.n or nil
                    if rn and prod[rn] then
                        emit(port(prod[rn], 'ret'), port(cname, 'self'))
                    elseif e.f.b.k == 'call' then
                        local inner = expr.dotted(e.f.b.f)
                        if inner then emit(port(inner, 'ret'), port(cname, 'self')) end
                    end
                end
                for i, a in ipairs(e.a or {}) do
                    if a.k == 'name' and prod[a.n] then
                        emit(port(prod[a.n], 'ret'), port(cname, 'a' .. i))
                    elseif a.k == 'call' then
                        -- direct nesting: B(A()) — no local mediates it
                        local inner = expr.dotted(a.f)
                        if inner then emit(port(inner, 'ret'), port(cname, 'a' .. i)) end
                    end
                end
            end
        end
        for k, v in pairs(e) do
            if k ~= 'f' or e.k ~= 'call' then
                if type(v) == 'table' then visit(v) end
            end
        end
        if e.k == 'call' and e.f then visit(e.f) end
    end
    for _, s in ipairs(fl.stmts or {}) do
        if s.expr then
            for _, x in ipairs(s.expr.rhs or {}) do visit(x) end
            for _, x in ipairs(s.expr.lhs or {}) do visit(x) end
            if s.expr.cond then visit(s.expr.cond) end
        end
    end
end

-- ── COLLECT: the observed flows, with NO unification yet ────────────────────
-- Split from partitioning deliberately (CART-0269): the propagation rules need every
-- port's DEGREE before deciding which ports may unify, and keeping collection separate
-- means the rules become a measurable MATRIX rather than a hardcoded choice.
local function collect()
    -- names DEFINED anywhere in the graph, so a port can be marked EXTERNAL. A port on
    -- a callee we can see is still a real port (and a resolved return type would TYPE
    -- the class it joins) — but the anonymous partition is about the ones we cannot.
    local known = {}
    for _, n in ipairs(store.data.nodes or {}) do
        if n.name then
            known[n.name] = true
            local last = n.name:match('([%w_]+)$')
            if last then known[last] = true end
        end
    end
    local pairsl, seen, pcount = {}, {}, {}
    local function emit(a, b)
        local k = a .. '\1' .. b
        if seen[k] then return end
        seen[k] = true
        pairsl[#pairsl + 1] = { a, b }
        pcount[a] = (pcount[a] or 0) + 1
        pcount[b] = (pcount[b] or 0) + 1
    end
    local nfn = 0
    for _, n in ipairs(store.data.nodes or {}) do
        if (n.kind == 'function' or n.kind == 'method') and n.file
            and n.file:match('%.lua$') and n.range then
            nfn = nfn + 1
            pcall(flows_of, n, emit)
        end
    end
    local function callee_of(p) return (p:match('^(.*)#[^#]*$')) or p end
    local function is_ext(p)
        local name = callee_of(p)
        local last = name:match('([%w_]+)$')
        return not (known[name] or (last and known[last]))
    end
    return { edges = pairsl, pcount = pcount, nfn = nfn,
        is_ext = is_ext, callee_of = callee_of, known = known }
end

-- ── THE PROPAGATION RULES (CART-0269) ───────────────────────────────────────
-- A UNIVERSAL SINK is a port that unifies values which have nothing to do with each
-- other. `ipairs#a1` accepts anything iterable, so every table in the corpus flows into
-- that ONE port and it fuses all of them in a single stroke — measured as the first
-- member of the blob on BOTH corpora (CART-0268). A sink's edges are still COLLECTED
-- (W3's data model wants the counts) but they do not TRANSIT: no edge incident to a sink
-- participates in unification, so a sink ends up unified with nothing, which is the
-- honest answer for a port that has no single type.
--
-- Three independent rules, each toggleable, because the matrix is the deliverable and
-- "neither rule alone suffices" is itself a finding:
--   builtin  the callee's ROOT name is a genuine builtin (builtins.lua's existing
--            roster — no new data). Catches ipairs / type / tostring / table.concat.
--            CANNOT catch `s:match` / `s:gsub` / `s:format`: those are bare method calls
--            with no dotted root, and their member signatures are exactly CART-0266's
--            gap. So this rule is a floor, not the mechanism.
--   method   an UNQUALIFIED callee (no dot) that is not a project definition is a bare
--            METHOD NAME whose receiver class is unknown, so the port fuses every
--            receiver in the corpus. Structural, needs no roster.
--   degree   the callee's degree sits far above the population. DERIVED FROM THE DATA,
--            so it generalizes to project-local sinks no roster would ever list — but it
--            is a CALIBRATION, so `--sweep` reports the whole curve instead of hiding a
--            magic number.
local builtins = require 'cartograph.builtins'
-- ONE RULE, and the matrix is what reduced it to one (CART-0269).
--
-- `bare`: the callee is UNQUALIFIED (no dot), is not a project definition, and its DEGREE
-- is at or above `mdeg`. Such a port fuses receivers/values that have nothing in common:
-- `match#self` (degree 59 here) collects every string in the corpus, `ipairs#a1` (137)
-- every table. Structural and degree-derived — no roster, and it generalizes to
-- project-local sinks no roster would list.
--
-- DEGREE-GATED, and the first version was NOT — that mattered. A categorical "every
-- unqualified callee is a sink" also condemned `Destroy#self` in the selftest, an engine
-- method with exactly ONE receiver class. A bare name fuses receivers only when receivers
-- ACTUALLY flow into it. 3 is deliberately low: two receivers can be a genuine shared
-- supertype, three is where fusion starts costing more than it explains.
--
-- ── A RULE THE MATRIX KILLED, kept here because the reason is the lesson ──────
-- There was a `builtin` rule: the callee's ROOT name is a genuine builtin per
-- builtins.lua. It looked obviously right and it is MEASURED WRONG — largest% fell to
-- 49.0% but `kept` dropped from 2/2 to 1/2, because **`vim` is in builtins.lua as an
-- always-present module table**, so the rule condemned every `vim.api.*` port and
-- destroyed the nvim WINDOW-HANDLE class. Being rooted at a builtin module table does not
-- make a function polymorphic. It also condemned `table.concat#ret`, whose return is a
-- string — and fusing all strings into one class is CORRECT, they ARE one type. The blob
-- is several genuine mega-types (string, table) fused by UNIVERSALLY polymorphic
-- functions; only the latter are sinks. `bare` already catches the useful part (a bare
-- global like `ipairs` is unqualified), so the roster rule bought nothing and cost a real
-- class. THE TWO-SIDED METRIC IS THE ONLY REASON THIS WAS VISIBLE — on largest% alone the
-- rule looked like a win.
local MDEG = 3
local function sinks_of(col, opts)
    local s = {}
    local mdeg = (opts.bare == true) and MDEG or opts.bare
    for p in pairs(col.pcount) do
        local name = col.callee_of(p)
        local unqualified = not name:find('.', 1, true)
        local deg = col.pcount[p] or 0
        if mdeg and unqualified and not col.known[name] and deg >= mdeg then
            s[p] = 'bare'
        elseif opts.degree and deg >= opts.degree then s[p] = 'degree'
        end
    end
    return s
end

local _ = builtins   -- kept required: the killed rule's rationale above cites its roster

local function partition(col, opts)
    local sinks = sinks_of(col, opts)
    local u = uf()
    local used = 0
    for _, e in ipairs(col.edges) do
        if not (sinks[e[1]] or sinks[e[2]]) then u:union(e[1], e[2]); used = used + 1 end
    end
    local cls = {}
    for k in pairs(u.p) do
        local r = u:find(k)
        cls[r] = cls[r] or {}
        table.insert(cls[r], k)
    end
    local list = {}
    for _, members in pairs(cls) do list[#list + 1] = members end
    table.sort(list, function (a, b) return #a > #b end)
    local nsink = 0
    for _ in pairs(sinks) do nsink = nsink + 1 end
    return { uf = u, classes = list, sinks = sinks, nsink = nsink,
        used = used, ports = u.n }
end

--- are all of `group`'s ports still in ONE class? The SECOND half of the two-sided
--- acceptance metric: breaking the blob by also breaking a real class trades one
--- worthless answer for another.
local function together(part, group)
    local root
    for _, p in ipairs(group) do
        if not part.uf.p[p] then return false end
        local r = part.uf:find(p)
        if root and r ~= root then return false end
        root = r
    end
    return root ~= nil
end

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
    local col = collect()
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
    vim.fn.delete(root, 'rf')
    return fails
end

-- ── main ────────────────────────────────────────────────────────────────────
local target = arg[1]
local show = 8
for i = 1, #(arg or {}) do if arg[i] == '--show' then show = tonumber(arg[i + 1]) or 8 end end

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
local col = collect()

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
