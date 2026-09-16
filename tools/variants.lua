-- variants — FIND OTHER IMPLEMENTATIONS OF ONE CONCEPT, INCLUDING INCOMPLETE ONES.
--
--   nvim --headless -u NONE -l tools/variants.lua <corpus|dir> --query <name>
--                                                 [--file PAT] [--k N] [--top N]
--
-- ★★★ THIS IS NOT CLONE DETECTION, AND CONFLATING THEM IS WHY IT LOOKED IMPOSSIBLE
-- (CART-0933). A clone is code that RESEMBLES other code. A concept VARIANT is a
-- second hand-written implementation of the same idea — and two implementations of
-- a GENERIC concept share only GENERIC code. MEASURED on the pair this was built
-- for (`ts.flow_stop` and expr.lua's `LOCALDECL_OF.__index`, both spelling
-- `base u declared \ withdrawn`, the second MISSING the withdrawal): they share
-- four subterm keys and three skeleton keys, every one among the commonest in the
-- corpus. SIX similarity methods ranked them no better than 135 of 2357, and IDF
-- weighting made it WORSE — IDF rewards sharing RARE features and these share none.
--
-- ★★★★ SO THE PREFILTER TAKES THE COMMONEST SHAPES, NOT THE RAREST, AND THAT
-- INVERSION IS THE WHOLE INSTRUMENT. MEASURED — the query's seven row shapes,
-- rarest first, against whether the known variant holds each:
--
--     df=4     no     df=157   YES
--     df=46    no     df=505   YES
--     df=154   no     df=1323  YES
--                     df=2013  YES
--
-- A MONOTONE SPLIT: the rare ones are exactly the ones the variant lacks. And the
-- reason is not about meaning — A SHAPE IS RARE PRECISELY BECAUSE MOST FUNCTIONS
-- LACK IT, and the variant is one of the many that lack it. "Rare" and "not shared
-- with some other arbitrary function" are the same property.
-- ⚠ I FIRST WROTE THAT THE RARE ROW WAS THE WITHDRAWAL LOOP — the missing piece
-- the variant is defective for. THAT WAS AN INFERENCE AND IT IS FALSE: none of the
-- three unshared shapes is the withdrawal (they are a nested call, a binary expr
-- and an indexed field), and at skeleton grain `out[k] = nil` and `out[k] = true`
-- collapse to the SAME shape anyway. The true mechanism is weaker, more general,
-- and does not depend on what the missing row MEANS.
-- ⇒ THE TRADE IS RARITY AGAINST RECALL: a rare shape is selective per shape and
-- costs recall; a common shape keeps recall and is useless alone. The CONJUNCTION
-- of several common shapes buys selectivity without paying recall — 2013 survivors
-- at k=1, 68 at k=4.
--
-- ★ THE PREFILTER IS SOUND: anything containing the concept must contain the shapes
-- declared required, so intersecting their posting lists has NO FALSE NEGATIVES. It
-- over-approximates and the ranker then runs on the survivors.
--
-- ⚠ THE RANKER IS THE WEAK STAGE AND IS KNOWN TO SATURATE. Inside a set already
-- narrowed to one shape family, "is it a merge loop" separates nothing — the top of
-- a real run was a SEVEN-WAY TIE. MEASURED on cartograph's own lua/ at eeaa90c:
-- 3087 functions -> 68 survivors (k=4) -> target ranked 42 of 67. ⇒ READ THIS AS A
-- NARROWING TOOL, NOT A RETRIEVER: 45x, target retained, survivors semantically
-- coherent. A human scans 68; nobody scans 3087. Claiming more than that is not
-- supported by any measurement here.
--
-- ⚠ AND RECALL DEPENDS ENTIRELY ON WHICH SHAPES ARE DECLARED REQUIRED. `--k`
-- picking the k commonest is a PROXY for a human stating the concept's core, and
-- the proxy is measured to break: at k=5 the target is lost. No automatic
-- substitute for authoring survived contact.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local here = repo .. '/tools/'
dofile(here .. 'bench.lua').bootstrap()

local at   = require 'cartograph.at'
local ts   = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local expr = require 'cartograph.expr'
local alg  = require 'cartograph.algebra'

local M = {}

--- every name leaf replaced by its FLOW ROLE. `inner` = bound by an EARLIER row of
--- this function, `free` = not. Structure is untouched, identity is erased.
--- ★ THE LINKED TERM IS THE MIDDLE OF THREE AND THE ONE TO USE. Measured collision
--- and promiscuity over 3087 functions: syntactic 2.6% / 0 of 391 at >=0.9;
--- LINKED 5.8% / 14; dataflow-only 12.8% / 217. A dataflow-only term matches the
--- pair at 0.965 and is USELESS — it matches 55% of the corpus that well.
local function roleize(A, t)
    if type(t) ~= 'table' then return t end
    if t.k == 'name' then return A.name(t.n == '\1local' and 'inner' or 'free') end
    if not t.kids or #t.kids == 0 then return t end
    local ks = {}
    for i, c in ipairs(t.kids) do ks[i] = roleize(A, c) end
    return A.node(t.k, (table.unpack or unpack)(ks))
end

--- a row term with every LEAF erased: pure shape, the prefilter's key.
local function skel(A, t)
    if type(t) ~= 'table' then return t end
    if not t.kids or #t.kids == 0 then return A.name('*') end
    local ks = {}
    for i, c in ipairs(t.kids) do ks[i] = skel(A, c) end
    return A.node(t.k, (table.unpack or unpack)(ks))
end

--- One record per function: its row SHAPES (the prefilter key set) and its two
--- terms. ⚠ `s.expr` IS A ROW ({lhs,rhs,cond}), NOT an expr node — `alg.row_term`
--- is the accessor; `alg.term` returns nil for a row and yields a UNIFORM ZERO
--- downstream, which reads as a clean finding and is not one.
--- @return table recs, table df  (df[shape] = how many functions hold it)
function M.index(root, opts)
    local A = alg.load()
    if not A then return {}, {} end
    store.ingest(ts.extract(root, opts and opts.packs and { packs = opts.packs } or nil))
    local recs, df = {}, {}
    for _, n in ipairs(store.data.nodes) do
        if (n.kind == 'function' or n.kind == 'method') and n.file then
            local ok, eo = pcall(expr.of, store, n.id)
            local stmts = ok and eo and eo.fl and eo.fl.stmts
            if stmts and #stmts >= 2 then
                local locals, inner = {}, {}
                for _, s in ipairs(stmts) do
                    for _, d in ipairs(s.def or {}) do locals[d] = true end
                end
                local syn, link, sk = {}, {}, {}
                for _, s in ipairs(stmts) do
                    if s.expr then
                        local rt = alg.row_term(s.expr, locals)
                        local lt = alg.row_term(s.expr, inner)
                        if rt then syn[#syn + 1] = rt; sk[A.show(skel(A, rt))] = true end
                        if lt then link[#link + 1] = roleize(A, lt) end
                    end
                    for _, d in ipairs(s.def or {}) do inner[d] = true end
                end
                recs[#recs + 1] = { name = tostring(n.name), file = n.file,
                    line = n.range and (at.sl(n.range) + 1) or 0, rows = #stmts,
                    shapes = sk, syn = A.seq(syn), link = A.seq(link) }
            end
        end
    end
    for _, r in ipairs(recs) do
        for k in pairs(r.shapes) do df[k] = (df[k] or 0) + 1 end
    end
    return recs, df
end

--- STAGE 1. The query's `k` row shapes, ORDERED BY FREQUENCY, intersected.
--- `order` is 'commonest' (the default, and the only one that works — see the ★★★★
--- note at the top) or 'rarest', kept so the inversion stays demonstrable.
--- @return table survivors (recs), table required (the shapes used, with counts)
function M.prefilter(recs, q, df, k, order)
    local req = {}
    for s in pairs(q.shapes) do req[#req + 1] = { k = s, n = df[s] or 0 } end
    table.sort(req, function (x, y)
        if order == 'rarest' then return x.n < y.n end
        return x.n > y.n
    end)
    local used = {}
    for i = 1, math.min(k, #req) do used[i] = req[i] end
    local out = {}
    for _, r in ipairs(recs) do
        local all = true
        for _, e in ipairs(used) do
            if not r.shapes[e.k] then all = false; break end
        end
        if all then out[#out + 1] = r end
    end
    return out, used
end

--- STAGE 2. Rank survivors by the LINKED term, tie-broken by the SYNTACTIC one.
--- ⚠ NORMALISED. `preserved_nodes` is an ABSOLUTE count, so ranking by it raw ranks
--- by SIZE — correct as an admission threshold, wrong as a score.
--- ⚠ A REFUSAL IS NOT A ZERO. `pair_family` returns ok=false with no `preserved`
--- when the generalizer declines; collapsing that to 0 ranks declines alongside
--- genuine mismatches, which is how two earlier rankings were misread (CART-0937).
function M.rank(q, survivors)
    local A = alg.load()
    local function score(field, a, b)
        local ok, info = alg.pair_family(a, b, { floor = 2 })
        if not ok then return nil end
        local d = math.min(A.size(a), A.size(b))
        return d > 0 and (info.preserved / d) or nil
    end
    local out = {}
    for _, r in ipairs(survivors) do
        if r ~= q then
            out[#out + 1] = { rec = r, link = score('link', q.link, r.link),
                syn = score('syn', q.syn, r.syn) }
        end
    end
    table.sort(out, function (x, y)
        local xl, yl = x.link or -1, y.link or -1
        if xl ~= yl then return xl > yl end
        return (x.syn or -1) > (y.syn or -1)
    end)
    return out
end

--- the whole pipeline. `match` picks the query: a function of (rec) -> boolean.
function M.run(root, match, opts)
    opts = opts or {}
    local recs, df = M.index(root, opts)
    local q
    for _, r in ipairs(recs) do if match(r) then q = r; break end end
    if not q then return nil, 'no function matched the query' end
    local survivors, used = M.prefilter(recs, q, df, opts.k or 4, opts.order)
    return { query = q, total = #recs, required = used,
        survivors = survivors, scored = M.rank(q, survivors) }
end

-- ── script form ──────────────────────────────────────────────────────────────
if pcall(debug.getlocal, 4, 1) then return M end

local root, qname, fpat, k, top = nil, nil, nil, 4, 15
local i = 1
while i <= #arg do
    if arg[i] == '--query' then qname = arg[i + 1]; i = i + 2
    elseif arg[i] == '--file' then fpat = arg[i + 1]; i = i + 2
    elseif arg[i] == '--k' then k = tonumber(arg[i + 1]); i = i + 2
    elseif arg[i] == '--top' then top = tonumber(arg[i + 1]); i = i + 2
    elseif not root then root = arg[i]; i = i + 1
    else print('unknown argument: ' .. arg[i]); os.exit(2) end
end
if not root or not qname then
    print('usage: variants.lua <corpus|dir> --query <name> [--file PAT] [--k N] [--top N]')
    os.exit(2)
end
local r, why = M.run(root, function (rec)
    return rec.name == qname and (not fpat or rec.file:find(fpat))
end, { k = k })
if not r then print('variants: ' .. tostring(why)); os.exit(1) end
print(('query %s  %s:%d  (%d rows)'):format(r.query.name, r.query.file,
    r.query.line, r.query.rows))
print(('corpus %d functions; required shapes (commonest first):'):format(r.total))
for _, e in ipairs(r.required) do
    print(('   held-by %-5d %s'):format(e.n, e.k:sub(1, 62)))
end
print(('⇒ %d survivors (%.1fx narrowing)'):format(#r.survivors,
    #r.survivors > 0 and r.total / #r.survivors or 0))
for j = 1, math.min(top, #r.scored) do
    local e = r.scored[j]
    print(('  %2d. link=%-6s syn=%-6s %-28s %s:%d'):format(j,
        e.link and ('%.3f'):format(e.link) or 'refused',
        e.syn and ('%.3f'):format(e.syn) or 'refused',
        e.rec.name, e.rec.file, e.rec.line))
end
