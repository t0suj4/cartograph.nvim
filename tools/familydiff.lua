-- familydiff — DOES THE PAIRWISE LGG COMPOSE? (CART-0888)
--
--   nvim --headless -u NONE -l tools/familydiff.lua <corpus|dir> [maxsize] [maxN]
--
-- `clones.near` returns PAIRS and `clones.extract_proposal` derives ONE helper
-- per pair. The algebra's `generalize(instances)` is N-ARY. The pairwise lgg
-- DOES NOT COMPOSE: lgg(a,b) and lgg(b,c) do not give lgg(a,b,c), because a
-- position CONSTANT across one pair can VARY across the family. So a connected
-- component of N near-clones yields up to C(N,2) helper proposals for what may
-- be one family.
--
-- ★ IT RIDES THE SHIPPED SEAM (`cartograph.algebra`, CART-0889), not its own
-- `dofile` and not its own adapter — one loader, one adapter, one authority.
--
-- ⚠ A COMPONENT IS NOT A FAMILY. `a~b`, `b~c` with `a≁c` is ONE component that
-- may be TWO families; generalizing over it collapses toward a bare hole. The
-- clique test and the N-ary retraction law are both reported for that reason,
-- and the failures are what `partition` exists for.
--
-- ⚠ HOLE COUNT IS NOT A GENERALITY ORDER. A template generalized HIGHER UP
-- trades several leaf holes for one hole subsuming the subtree, so a MORE
-- general template can carry FEWER holes (observed on desynced). The sound
-- signals here are DISAGREEMENT (min ~= max across a component's pairs) and
-- RETRACTION; "over-specific" is a proxy and is labelled as one.
--
-- ⚠ THE POPULATION IS PRINTED, NOT ASSUMED. Every number inherits `clones.near`'s
-- max_dist / min_rows / min_shared, plus BOTH guards below — the pairwise leg is
-- C(N,2) at FUNCTION scale (0.2-12 s per call, measured), so a component of 50
-- is 1225 calls and would never return. A run that never returns is not a NO-GO,
-- it is no measurement at all.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local here = repo .. '/tools/'
dofile(here .. 'bench.lua').bootstrap()
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local clones = require 'cartograph.clones'
local alg = require 'cartograph.algebra'
local A = assert(alg.load(), 'algebra unavailable')

local target = arg[1]
local MAXSZ = tonumber(arg[2]) or 4000
local MAXN = tonumber(arg[3]) or 12
local reg = dofile(repo .. '/tools/corpora.lua')
local c = reg[target]
local root = c and vim.fn.expand(c.root) or vim.fn.expand(target)
store.ingest(ts.extract(root, c and c.packs and { packs = c.packs } or nil))

local MAX_DIST, MIN_ROWS, MIN_SHARED = 2, 6, 2   -- clones.near's own defaults
local pairs_ = clones.near(store, {})

local fn_term = alg.fn_term
-- ⚠ `A.generalize` RETURNS A RESULT RECORD, NOT A TEMPLATE. Its own internal
-- recursive call reads `base.template`, and the driver reads `g.template.holes`.
-- Counting holes on the record itself yields 0 for EVERY input, because the
-- record has no `k` and no `kids` -- a falsy answer that is a claim about the
-- accessor, not about the data ([[ask-the-accessor-not-the-container]]). The
-- first cut of this script did exactly that and reported "0 holes over 28 pairs"
-- across the board, which is the shape of a measurement that never ran.
local function nholes(tmpl)
    local n = 0
    for _ in pairs(tmpl.holes or {}) do n = n + 1 end
    return n
end

--- the lgg's own law: instantiating each valuation must reproduce its instance.
--- For N instances this is the real question -- a family template that cannot
--- retract to all N is not a family template.
local function retracts(g, terms)
    for i = 1, #terms do
        local r = A.instantiate(g.template, g.values[i])
        if not (r and A.eq(r.term, terms[i])) then return false end
    end
    return true
end

-- union-find over pair endpoints
local up, rec, adj = {}, {}, {}
local function find(x) while up[x] and up[x] ~= x do x = up[x] end return x end
for _, p in ipairs(pairs_) do
    rec[p.a.id] = p.a; rec[p.b.id] = p.b
    up[p.a.id] = up[p.a.id] or p.a.id; up[p.b.id] = up[p.b.id] or p.b.id
    local ra, rb = find(p.a.id), find(p.b.id); if ra ~= rb then up[ra] = rb end
    adj[p.a.id] = adj[p.a.id] or {}; adj[p.a.id][p.b.id] = p
    adj[p.b.id] = adj[p.b.id] or {}; adj[p.b.id][p.a.id] = p
end
local members = {}
for id in pairs(up) do
    local r = find(id); members[r] = members[r] or {}
    table.insert(members[r], id)
end

local tally, order = {}, {}
local function bump(k, n)
    if not tally[k] then order[#order + 1] = k end
    tally[k] = (tally[k] or 0) + (n or 1)
end

local fams, big, examined = 0, 0, 0
for _, ids in pairs(members) do
    fams = fams + 1
    bump(('family size %3d'):format(#ids))
    if #ids > 2 then
        big = big + 1
        -- is the component a CLIQUE? if not, `generalize` is the wrong arrow
        local edges, want = 0, #ids * (#ids - 1) / 2
        for i = 1, #ids do for j = i + 1, #ids do
            if adj[ids[i]] and adj[ids[i]][ids[j]] then edges = edges + 1 end
        end end
        local clique = edges == want
        bump(clique and 'component IS a clique (one family)'
            or 'component is a CHAIN, not a clique (partition first)')

        -- ⚠ TWO GUARDS, BOTH REPORTED, BECAUSE THE PAIRWISE LEG IS C(N,2) AT
        -- FUNCTION SCALE -- 0.2-12 s per call, measured. A component of 50 is
        -- 1225 calls and would never finish; a run that silently never returns
        -- is not a NO-GO, it is no measurement at all. So: cap the family size
        -- AND the total term size, and COUNT what was skipped so the population
        -- the numbers describe is visible.
        if #ids > MAXN then
            bump(('SKIPPED: family larger than %d (C(N,2) at function scale)'):format(MAXN))
            goto continue
        end
        local terms, total = {}, 0
        for _, id in ipairs(ids) do
            local t = fn_term(rec[id]); terms[#terms + 1] = t; total = total + A.size(t)
        end
        if total > MAXSZ then
            bump('SKIPPED: over the size guard')
        else
            examined = examined + 1
            local okf, fam = pcall(A.generalize, terms)
            if not okf or not fam or not fam.template then
                bump('family generalize FAILED: ' .. tostring(fam):sub(1, 50))
            else
                local famholes = nholes(fam.template)
                -- ★ RETRACTION IS NOT EVIDENCE OF A FAMILY ON ITS OWN. Report it
                -- beside the FIXED-NODE count, which is the prototype's own
                -- admissibility test (`partition`'s min_fixed).
                local fixed = alg.fixed_nodes(fam.template.body)
                bump(retracts(fam, terms)
                    and '  family RETRACTION HOLDS over all N'
                    or '★ family RETRACTION FAILS (not one family)')
                bump(fixed == 0 and '★ family template shares NO fixed structure'
                    or fixed < 5 and '  family shares 1-4 fixed nodes'
                    or '  family shares 5+ fixed nodes')
                -- ⚠⚠ THIS CHECK WAS DEAD IN THE FIRST CUT AND NEVER ONCE FIRED.
                -- It read `fam.template.k`, but a TEMPLATE is a record
                -- `{ body, holes, edits }` -- the TERM is `template.body`, so
                -- `.k` was nil for every family. A bare-hole template RETRACTS
                -- TO EVERY INSTANCE TRIVIALLY, so the "retraction holds" tally it
                -- fell through to was counting exactly the not-a-family case it
                -- was supposed to exclude.
                if alg.is_collapsed(fam.template) then
                    bump('family lgg COLLAPSED to a bare hole (not one family)')
                else
                    -- ★★★ THE DEFECT IS NOT "the family beats the BEST pair".
                    -- It is that the N pairwise proposals DISAGREE WITH EACH
                    -- OTHER, because extract_proposal emits one helper PER PAIR:
                    -- a family of 5 becomes up to 10 proposals for one helper.
                    -- So compare the family against the LEAST general pair too --
                    -- every pair below the family's hole count is a proposal that
                    -- is OVER-SPECIFIC for the family it belongs to.
                    local maxpair, minpair, np = -1, math.huge, 0
                    for i = 1, #ids do for j = i + 1, #ids do
                        local okp, g = pcall(A.generalize, { terms[i], terms[j] })
                        if okp and g and g.template then
                            local n = nholes(g.template)
                            np = np + 1
                            maxpair = math.max(maxpair, n)
                            minpair = math.min(minpair, n)
                        end
                    end end
                    if maxpair < 0 then bump('no pairwise lgg computable')
                    else
                        bump(minpair ~= maxpair
                            and ('★ PAIRWISE PROPOSALS DISAGREE within one family'
                                 .. ' (%d..%d holes over %d pairs)'):format(
                                 minpair, maxpair, np)
                            or ('pairwise proposals AGREE across the family'
                                .. ' (%d holes over %d pairs)'):format(maxpair, np))
                        if famholes > maxpair then
                            bump('★ family lgg MORE GENERAL than every pair')
                        elseif famholes == maxpair then
                            bump('family lgg == most general pair')
                        else
                            bump('family lgg has FEWER holes than the best pair')
                        end
                        if famholes > minpair then
                            bump('★ at least one pairwise proposal is OVER-SPECIFIC'
                                .. ' for its family')
                        end
                    end
                end
            end
        end
    end
    ::continue::
end

print(('corpus %s — POPULATION: clones.near defaults max_dist=%d min_rows=%d'
    .. ' min_shared=%d; size guard %d; family-size guard %d'):format(target,
    MAX_DIST, MIN_ROWS, MIN_SHARED, MAXSZ, MAXN))
print(('%d pairs, %d families, %d of size >2, %d examined'):format(
    #pairs_, fams, big, examined))
table.sort(order)
for _, k in ipairs(order) do
    if not k:match('^family size') or tally[k] then
        print(('  %-62s %5d'):format(k, tally[k]))
    end
end
