-- The STATE ATLAS: every module var classified by its use-edge facts —
-- the write axis (rw), guard summaries (gw) and param predicates (gp)
-- composed into a state-discipline map ([[cartograph-write-axis]]):
--
--   const          no function writes it (init-time writes are not use
--                  edges, so 'const' means constant AFTER load)
--   dead           written, never read — dead state (or dynamic access
--                  the graph can't see: the ~ hedge, always spoken)
--   set-once       every write edge is all-set-once (gw=3): init-shaped
--                  state, writes COMMUTE
--   single-writer  one owning fn writes, others only read — an ownership
--                  invariant worth knowing when it breaks
--   multi-writer   contended state: the reorder/race attention list
--   unclassified   some use edge carries no rw (a language without the
--                  write classifier) — unknown, never guessed
--   unobserved     NO use edge at all, and no derived read when one was asked
--                  for: nothing was seen, so nothing is claimed (CART-0478)
--
-- Pure consumer: no extraction change, every fact already in the graph.

-- @langs lua php javascript python typescript tsx
-- NOT a lua module despite the neighbours: `field_of` reads php's `variable_name`
-- wrapper and pairs `dot_index_expression`/`member_access_expression` and
-- `bracket_index_expression`/`subscript_expression` as or-groups — it was written
-- polyglot and nothing said so (the spec/javascript.lua precedent, CART-0304).
local M = {}

M.LABELS = { 'const', 'dead', 'set-once', 'single-writer', 'multi-writer',
    'unclassified', 'unobserved' }

-- ── WHY `unobserved` EXISTS (CART-0478) ─────────────────────────────────────
-- `nw == 0 -> const` was tested BEFORE any evidence check, so a var with NO use
-- edge of any kind -- nothing read, nothing written, nothing known -- got the
-- STRONGEST WORD ON THE LADDER. `const` is a positive claim about immutability,
-- and an empty set cannot support one: the honesty invariant is that ABSENCE IS
-- NOT EVIDENCE, violated here in the loudest possible way.
--
-- MEASURED, and the population is what makes this a fix rather than a downgrade.
-- Every zero-evidence var was labelled `const`, 605 of 605 on mantis:
--     corpus              vars   const today   zero evidence   asking keyaccess
--     mantisbt            2537   2044 (81%)         605              213
--     cartograph (lua)     847    691               1                1
--     grocy                171     92              29               29
--     jquery                41      2               0                0
-- The browser and the dead-state lint both ASK for derived reads, so what a reader
-- actually sees relabelled on mantis is 213 vars, not 605 -- the rest are `const`
-- with evidence behind them now (CART-0479 gave file-scope mentions an owner,
-- CART-0507 made string-keyed reads visible). Doing this ticket FIRST, before
-- either of those, would have hedged ~2000 knowable facts.
--
-- ★ IT IS A DIFFERENT FACT FROM `unclassified`, and the boundary is NO EDGES vs
-- UNREADABLE EDGES. jquery has 38 vars with edges whose `rw` is nil (javascript
-- ships no write classifier) -- those are `unclassified`, which already says
-- "unknown, never guessed", and NONE of them is unobserved. A probe that tested
-- `nr == 0 and nw == 0` instead conflated the two and reported jquery as 38
-- unobserved out of 41; the predicate is the EDGE COUNT, not the counters.

--- Classify one var by its use edges. Returns
--- { label, nr, nw, writers = {fn ids}, gw = min guard tier of writes }.
--- @param opts table|nil  { derived = true } -> also count STRING-KEYED reads
---   ([[cartograph-keyaccess]]). OPT-IN, and default-off is deliberate: this
---   consults an index that re-parses accessor files (~525 ms once on mantis),
---   and turning it on silently would change one caller's findings without anyone
---   deciding. A caller that wants the truth asks for it.
---
---   ★ WHAT IT ACTUALLY CHANGES, measured on mantis before it was built, because
---   the obvious guess was wrong: the ladder tests `nw == 0 -> const` BEFORE
---   `nr == 0 -> dead`, so the 392 vars whose only readers are string-keyed were
---   already `const` and STAY `const`. What they gain is EVIDENCE -- `const` on
---   nothing becomes `const` on seven reads, which is the distinction CART-0478
---   exists to make. The label-flip population (`dead` -> a writer label, i.e. a
---   var written by a fn and read only by key) is exactly ONE var on mantis.
---   Small, and still worth wiring: a promise rule that ignores refuting evidence
---   it could have consulted is wrong, not conservative.
function M.classify(store, id, opts)
    local nr, nw, unk, gwmin = 0, 0, false, nil
    local writers = {}
    local nedge = 0
    for _, u in ipairs(store.topo():var_used_by_detail(id)) do
        nedge = nedge + 1
        local rw = u.rw
        if not rw then
            unk = true
        else
            if rw == 1 or rw == 3 then nr = nr + 1 end
            if rw >= 2 then
                nw = nw + 1
                writers[nw] = u.from
                local g = u.gw or 1
                if not gwmin or g < gwmin then gwmin = g end
            end
        end
    end
    -- derived reads are READS: a call with a literal key was SEEN, so each is a
    -- witness, and they enter the ladder on the same footing. They are counted
    -- separately as well (`dnr`) because a reader is owed the difference between a
    -- read spelled as an identifier and one spelled as data -- the label does not
    -- carry it, the rows do.
    local dnr = 0
    if opts and opts.derived then
        dnr = #require('cartograph.keyaccess').reads_of(store, id)
        nr = nr + dnr
    end
    local label
    -- THE EVIDENCE CHECK COMES FIRST. Everything below it reads a COUNT, and a
    -- count of zero over an empty set is not a fact about the code.
    if nedge == 0 and dnr == 0 then label = 'unobserved'
    elseif unk then label = 'unclassified'
    elseif nw == 0 then label = 'const'
    elseif nr == 0 then label = 'dead'
    elseif gwmin == 3 then label = 'set-once'
    elseif nw == 1 then label = 'single-writer'
    else label = 'multi-writer' end
    -- NO `~` ON THE LABEL, deliberately. A derived read does not weaken `const`:
    -- reads never threaten constancy, writes do, and there are none. What the
    -- reads change is const-on-nothing -> const-with-evidence, a STRENGTHENING.
    -- So the honest surface is a count ("const · 7 reads (7 via config_get)") and
    -- per-row marks, not a hedge glyph implying doubt about the label.
    return { label = label, nr = nr, nw = nw, writers = writers, gw = gwmin,
        dnr = dnr > 0 and dnr or nil }
end

-- ── the FIELD atlas: one var, decomposed per field, on demand ────────────
-- Fields are not nodes — the edge facts aggregate over them (`state` is
-- multi-writer even when x has one owner and y is set-once). This
-- re-parses the var's consumer files (the detail.lua pattern) and reruns
-- the SAME write/guard classifiers on the live nodes, grouped by the
-- occurrence's immediate field. Whole-var accesses (`f(state)`,
-- `pairs(state)`, rebinds) land in the '(whole)' bucket; a whole-var
-- WRITE hedges every field claim (it could have written anything).

local function ext_spec(file)
    local ts = require 'cartograph.providers.treesitter'
    local ext = file:match('%.([%w_]+)$')
    if not ext then return nil end
    for lang, spec in pairs(ts.spec) do
        for _, e in ipairs(spec.exts or {}) do
            if e == ext then return lang, spec end
        end
    end
end

-- the immediate field of a base-var occurrence, or nil for a whole-var use
local function field_of(c, src)
    local p = c:parent()
    -- @langs-ok php's `$x` wrapper; a no-op peel on every other declared grammar
    if p and p:type() == 'variable_name' then c = p; p = p:parent() end -- php $x
    if not p then return nil end
    local t = p:type()
    if t == 'dot_index_expression' or t == 'member_access_expression' then
        if p:named_child(0) ~= c then return nil end
        local f = p:named_child(1)
        return f and vim.treesitter.get_node_text(f, src) or '[]'
    end
    if t == 'bracket_index_expression' or t == 'subscript_expression' then
        if p:named_child(0) ~= c then return nil end
        local k = p:named_child(1)
        if k and k:type() == 'string' then
            local inner = k:named_child(0)
            if inner then return vim.treesitter.get_node_text(inner, src) end
        end
        return '[]' -- computed key: one bucket, honestly coarse
    end
    return nil
end

--- Per-field classification of one var. `cache` (optional) shares parsed
--- trees across calls (the census sweep). Returns nil, why on refusal.
--- { fields = { name -> {label, nr, nw, writers={set}, hedged} },
---   whole = { nr, nw }, files = n }
function M.fields(store, id, cache)
    local ts = require 'cartograph.providers.treesitter'
    local atr = require 'cartograph.at'
    local uses = store.topo():var_used_by_detail(id)
    if #uses == 0 then return nil, 'no uses' end
    cache = cache or {}
    local fields, whole = {}, { nr = 0, nw = 0 }
    for _, u in ipairs(uses) do
        local fn = store.node(u.from)
        local file = fn and fn.file
        if file then
            local entry = cache[file]
            if entry == nil then
                local lang, spec = ext_spec(file)
                if lang and spec and spec.is_write then
                    local fd = io.open(store.abs(file), 'r')
                    if fd then
                        local src = fd:read('*a')
                        fd:close()
                        local okp, parser =
                            pcall(vim.treesitter.get_string_parser, src, lang)
                        if okp and parser then
                            local okt, tree = pcall(function ()
                                return parser:parse()[1]
                            end)
                            if okt and tree then
                                entry = { root = tree:root(), src = src, spec = spec }
                            end
                        end
                    end
                end
                entry = entry or false
                cache[file] = entry
            end
            if entry then
                local root, src, spec = entry.root, entry.src, entry.spec
                for _, r in ipairs(u.at or {}) do
                    local sl, sc = atr.sl(r), atr.sc(r)
                    local c = root:named_descendant_for_range(sl, sc, sl, sc + 1)
                    if c then
                        local f = field_of(c, src)
                        local n = c:parent()
                        local w = n and spec.is_write(c, n)
                        if not f then
                            if w then whole.nw = whole.nw + 1
                            else whole.nr = whole.nr + 1 end
                        else
                            local rec = fields[f]
                            if not rec then
                                rec = { nr = 0, nw = 0, writers = {}, gw = nil }
                                fields[f] = rec
                            end
                            if w then
                                rec.nw = rec.nw + 1
                                rec.writers[u.from] = true
                                local g = spec.guards
                                    and ts.guard_class(c, n, src, spec.guards) + 1
                                    or 1
                                if not rec.gw or g < rec.gw then rec.gw = g end
                            else
                                rec.nr = rec.nr + 1
                            end
                        end
                    end
                end
            end
        end
    end
    local nfiles = 0
    for _, e in pairs(cache) do if e then nfiles = nfiles + 1 end end
    for _, rec in pairs(fields) do
        local nwriters = 0
        for _ in pairs(rec.writers) do nwriters = nwriters + 1 end
        if rec.nw == 0 then rec.label = rec.nr > 0 and 'const' or 'const'
        elseif rec.nr == 0 then rec.label = 'dead'
        elseif rec.gw == 3 then rec.label = 'set-once'
        elseif nwriters == 1 then rec.label = 'single-writer'
        else rec.label = 'multi-writer' end
        rec.nwriters = nwriters
        -- a whole-var write could touch ANY field: every claim hedged
        if whole.nw > 0 then rec.hedged = true end
    end
    return { fields = fields, whole = whole, files = nfiles }
end

--- The whole graph's census: counts per label + the var lists.
---
--- WHAT IT EXCLUDES IS THE TEST BELOW, AND ONLY THAT (read it, do not trust a
--- summary here): `n.sql`, `n.ctype`, and the `sql::` id prefix. That pair is
--- the RESOLVER's var vocabulary (treesitter.lua), copied here — and copying
--- it was the mistake, because the resolver runs BEFORE any post-pass adapter
--- attaches and this does not. So this is NOT "synthetic/browse-only vars are
--- excluded", as it used to claim: the adapter-minted `kind='var'` entities
--- (django `route::`, symfony `sfroute::`, ansible `handler::`/`ansvar::`,
--- dblink's imported tables) carry their own marker fields, are named in no
--- list here, and therefore ARE counted and classified on the write axis.
--- They have `use` edges and no writes by construction, so they land on
--- `const` or `unobserved` and inflate those buckets — which matters because
--- this census feeds the `dead-state` lint's population. Known wart, not a
--- design: see kb `synthetic-var-node-families` for the family roster and the
--- other two filters that each hand-list a different subset.
--- @param opts table|nil  threaded to classify (see `derived`)
function M.census(store, opts)
    local counts, vars = {}, {}
    for _, l in ipairs(M.LABELS) do counts[l] = 0; vars[l] = {} end
    local total = 0
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'var' and not n.sql and not n.ctype
            and n.id:sub(1, 5) ~= 'sql::' then
            total = total + 1
            local c = M.classify(store, n.id, opts)
            counts[c.label] = counts[c.label] + 1
            table.insert(vars[c.label], { id = n.id, name = n.name,
                file = n.file, nr = c.nr, nw = c.nw, dnr = c.dnr })
        end
    end
    return { total = total, counts = counts, vars = vars }
end

return M
