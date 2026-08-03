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

-- ── the sweep ───────────────────────────────────────────────────────────────
local function build()
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
    local u = uf()
    local edges, seen = 0, {}
    local pcount = {}
    local function emit(a, b)
        local k = a .. '\1' .. b
        if seen[k] then return end
        seen[k] = true
        edges = edges + 1
        pcount[a] = (pcount[a] or 0) + 1
        pcount[b] = (pcount[b] or 0) + 1
        u:union(a, b)
    end
    local nfn = 0
    for _, n in ipairs(store.data.nodes or {}) do
        if (n.kind == 'function' or n.kind == 'method') and n.file
            and n.file:match('%.lua$') and n.range then
            nfn = nfn + 1
            pcall(flows_of, n, emit)
        end
    end
    -- classes
    local cls = {}
    for k in pairs(u.p) do
        local r = u:find(k)
        cls[r] = cls[r] or {}
        table.insert(cls[r], k)
    end
    local list = {}
    for _, members in pairs(cls) do list[#list + 1] = members end
    table.sort(list, function (a, b) return #a > #b end)
    -- externality of a port's callee
    local function is_ext(p)
        local name = p:match('^(.*)#[^#]*$') or p
        local last = name:match('([%w_]+)$')
        return not (known[name] or (last and known[last]))
    end
    return { uf = u, edges = edges, classes = list, nfn = nfn,
        pcount = pcount, is_ext = is_ext }
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
    'M.chain, M.nested, M.meth, M.other = chain, nested, meth, other',
    'return M',
}, '\n') .. '\n'

local function selftest()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/fx.lua', 'w')); fd:write(FIXTURE); fd:close()
    store.ingest(ts.extract(root))
    local g = build()
    local fails = {}
    local function chk(c, m) if not c then fails[#fails + 1] = m end end
    local FC = port('Engine.FindComponent', 'ret')
    local function same(a, b) return g.uf.p[a] and g.uf.p[b] and g.uf:find(a) == g.uf:find(b) end
    chk(same(FC, port('Engine.RemoveFromParent', 'a1')),
        'local-mediated flow must link FindComponent.ret ~ RemoveFromParent.a1')
    chk(same(FC, port('Engine.Attach', 'a1')),
        'DIRECT NESTING must link FindComponent.ret ~ Attach.a1')
    chk(same(FC, port('Destroy', 'self')),
        'a METHOD RECEIVER must be a port: FindComponent.ret ~ Destroy.self')
    -- the socket family is a DIFFERENT opaque type and must stay separate: if these
    -- merge, the partition is worthless and the test would not notice
    chk(g.uf.p[port('Engine.OpenSocket', 'ret')], 'the socket family is present')
    chk(not same(FC, port('Engine.OpenSocket', 'ret')),
        'DISTINCT opaque families must NOT merge (the whole value of a partition)')
    chk(g.is_ext(FC), 'Engine.FindComponent is EXTERNAL (absent from the corpus)')
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
print('  ok — local-mediated / direct-nested / method-receiver flows all link;'
    .. ' two distinct opaque families stay SEPARATE; externality detected')

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
local g = build()

local ext, tot = 0, 0
for p in pairs(g.uf.p) do
    tot = tot + 1
    if g.is_ext(p) then ext = ext + 1 end
end
print(('  %d lua fn(s) walked · %d PORT(s) (%d external, %.0f%%) · %d observed EDGE(s)')
    :format(g.nfn, tot, ext, tot > 0 and 100 * ext / tot or 0, g.edges))
print(('  %d class(es)'):format(#g.classes))

-- THE BASELINE W2 (CART-0269) HAS TO IMPROVE. A fat top class is the EXPECTED naive
-- result, not a failure of this tool.
local big = g.classes[1] and #g.classes[1] or 0
print(('  ★ BASELINE class-size distribution — largest class holds %d / %d ports (%.1f%%)')
    :format(big, tot, tot > 0 and 100 * big / tot or 0))
local buckets, hist = {}, {}
for _, m in ipairs(g.classes) do hist[#m] = (hist[#m] or 0) + 1 end
local sizes = {}
for k in pairs(hist) do sizes[#sizes + 1] = k end
table.sort(sizes)
for _, k in ipairs(sizes) do buckets[#buckets + 1] = ('%d:%d'):format(k, hist[k]) end
print(('    size:count  %s'):format(table.concat(buckets, ' ')))
if tot > 0 and big / tot > 0.5 then
    print('    → DEGENERATE (>50% in one class), which is what W2\'s propagation rules'
        .. ' exist to fix — this is the number to beat, not a verdict on the idea')
end

-- THE W2 WORK-LIST. A port's DEGREE is how many distinct flows touch it, and a
-- high-degree port is a UNIVERSAL SINK: `ipairs#a1` accepts anything iterable, so every
-- table in the corpus flows into it and that ONE port unifies all of them. Measured on
-- both corpora, `ipairs#a1` is the top member of the blob — so the dominant over-merge
-- source is POLYMORPHIC STDLIB FUNCTIONS, not the passthrough project function I
-- expected. Degree is derivable from the data, which makes the W2 rule measurable rather
-- than a hand-maintained blocklist.
print('')
print('  TOP PORTS BY DEGREE (the W2 work-list — a universal sink unifies its neighbours):')
local pd = {}
for p, n in pairs(g.pcount) do pd[#pd + 1] = { p = p, n = n } end
table.sort(pd, function (a, b) return a.n > b.n end)
for i = 1, math.min(#pd, 8) do
    print(('    %-42s degree %d%s'):format(pd[i].p, pd[i].n,
        g.is_ext(pd[i].p) and '' or '  (resolved)'))
end

print('')
print(('  LARGEST CLASSES (a class = ports observed to hold interchangeable values):'))
for i = 1, math.min(#g.classes, show) do
    local m = g.classes[i]
    table.sort(m, function (a, b) return (g.pcount[a] or 0) > (g.pcount[b] or 0) end)
    local shown = {}
    for j = 1, math.min(#m, 6) do shown[#shown + 1] = m[j] end
    print(('    [%d ports] %s%s'):format(#m, table.concat(shown, '  '),
        #m > 6 and ('  … +' .. (#m - 6)) or ''))
end
